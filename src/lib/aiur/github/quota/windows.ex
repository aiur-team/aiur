defmodule Aiur.GitHub.Quota.Windows do
  @moduledoc false

  alias Aiur.GitHub.Budget
  alias Aiur.GitHub.Access.Settings
  alias Aiur.GitHub.{EndpointPolicy, GraphQLCost, GraphQLErrors, Transport}

  @primary_resources ~w(core graphql)
  @rate_limit_body_resources ~w(core)
  # Anonymous reads bill the 60/hr unauthenticated IP allowance, not the
  # authenticated core budget. They get their own window so an exhausted
  # anonymous allowance stays visible without gating fleet dispatch, and so a
  # `limit: 60` response can never overwrite the authenticated `core` window.
  @anonymous_resource "core:anonymous"
  @route_core_resources ~w(core:issue_dependencies core:sub_issues)
  @metered_resources [@anonymous_resource | @primary_resources ++ @route_core_resources]
  @issue_dependencies_path ~r{/issues/\d+/dependencies/blocked_by/?$}
  @sub_issues_path ~r{/issues/\d+/sub_issues/?$}
  @low_water_percent 10.0

  # Top-level `core`/`graphql` windows remain the primary credential meter used
  # by existing surfaces and dispatch. Every credential also gets a keyed
  # window under `credential_windows` for diagnostics and separate display.

  # GitHub does not always say how long a secondary limit lasts. Its own
  # guidance is to wait at least a minute, and the ceiling keeps a hostile or
  # malformed `Retry-After` from parking the whole fleet for hours.
  @secondary_backoff_seconds 60
  @max_secondary_backoff_seconds 60 * 60

  @spec observe_response(map(), map(), term(), DateTime.t()) :: map()
  def observe_response(state, request, {:ok, %{body: %{"resources" => resources}}}, now) when is_map(resources) do
    Enum.reduce(@rate_limit_body_resources, state, fn resource, acc ->
      case Map.get(resources, resource) do
        %{} = values -> put_credential_window(acc, request, resource, values, now)
        _missing -> acc
      end
    end)
  end

  # Successful instrumented GraphQL responses report `rateLimit { limit
  # remaining resetAt }` in their body. Secondary-limit responses are excluded
  # before window ingestion because their headers do not establish primary
  # exhaustion.
  def observe_response(state, request, {:ok, response}, now) when is_map(response) do
    if GraphQLErrors.secondary_rate_limited_response?(response) do
      state
    else
      case graphql_rate_limit_values(request, response) do
        %{} = values -> put_credential_window(state, request, "graphql", values, now)
        nil -> observe_response_headers(state, request, response, now)
      end
    end
  end

  def observe_response(state, _request, _result, _now), do: state

  defp graphql_rate_limit_values(request, response) do
    with "graphql" <- request_resource(request),
         %{limit: limit, remaining: remaining, reset_at: reset_at} when is_integer(limit) and is_integer(remaining) <-
           GraphQLCost.reported(response),
         {:ok, reset, _offset} <- reset_at |> to_string() |> DateTime.from_iso8601() do
      %{"limit" => limit, "remaining" => remaining, "reset" => DateTime.to_unix(reset)}
    else
      _unreported -> nil
    end
  end

  defp observe_response_headers(state, request, response, now) do
    headers = Map.get(response, :headers, [])

    # GitHub reports `core` for an anonymous read too, but that is a different
    # 60/hr budget. Trust the request, not the header, when deciding which
    # window the response describes.
    resource =
      case request_resource(request) do
        @anonymous_resource -> @anonymous_resource
        _authenticated -> Transport.header(headers, "x-ratelimit-resource")
      end

    resource = route_specific_resource(resource, request)

    if resource in @metered_resources do
      values = %{
        "limit" => Transport.header(headers, "x-ratelimit-limit"),
        "remaining" => Transport.header(headers, "x-ratelimit-remaining"),
        "reset" => Transport.header(headers, "x-ratelimit-reset")
      }

      put_credential_window(state, request, resource, values, now)
    else
      state
    end
  end

  defp route_specific_resource("core", %{url: url}) when is_binary(url) do
    path = URI.parse(url).path || ""

    cond do
      Regex.match?(@issue_dependencies_path, path) -> "core:issue_dependencies"
      Regex.match?(@sub_issues_path, path) -> "core:sub_issues"
      true -> "core"
    end
  end

  defp route_specific_resource(resource, _request), do: resource

  defp put_credential_window(state, request, resource, values, now) do
    state = prune_credential_windows(state, now)
    credential_id = Map.get(request, :credential_id, "unregistered")
    key = credential_key(request)

    case {request_resource(request), credential_id, key, parse_window(resource, values, now)} do
      {@anonymous_resource, _credential_id, _key, _window} ->
        put_window_from_values(state, resource, values, now)

      {_request_resource, "primary", nil, _window} ->
        put_window_from_values(state, resource, values, now)

      {_request_resource, "primary", key, %{} = window} when is_binary(key) ->
        put_primary_credential_window(state, resource, key, window, values, now)

      {_request_resource, credential_id, key, %{} = window} when is_binary(credential_id) and is_binary(key) ->
        put_secondary_credential_window(state, resource, key, window)

      {_request_resource, _credential_id, _key, _window} ->
        state
    end
  end

  defp put_primary_credential_window(state, resource, key, window, values, now) do
    state = put_secondary_credential_window(state, resource, key, window)

    if resource in @primary_resources do
      put_window_from_values(state, resource, values, now)
    else
      state
    end
  end

  defp put_secondary_credential_window(state, resource, key, window) do
    windows = Map.put(state.credential_windows, {key, resource}, window)
    %{state | credential_windows: windows}
  end

  defp prune_credential_windows(state, now) do
    windows =
      state.credential_windows
      |> Enum.reject(fn {_key, window} -> DateTime.compare(window.reset_at, now) != :gt end)
      |> Map.new()

    %{state | credential_windows: windows}
  end

  defp credential_key(%{credential_key: key}) when is_binary(key) and key != "", do: key

  defp credential_key(%{credential_id: credential_id}) when is_binary(credential_id) and credential_id != "" do
    Budget.identity_key("github-credential:" <> credential_id)
  end

  defp credential_key(%{credential_id: _credential_id}), do: nil

  defp credential_key(%{token: token}) when is_binary(token) and token != "", do: Budget.token_key(token)
  defp credential_key(_request), do: nil

  defp put_window_from_values(state, resource, values, now) do
    case parse_window(resource, values, now) do
      %{} = window ->
        state
        |> Map.put(:windows, Map.put(state.windows, resource, window))
        |> reconcile_resource_alerts(resource, window)
        |> sync_hold_file(resource, window)

      nil ->
        state
    end
  end

  defp parse_window(resource, values, now) do
    with {:ok, limit} <- integer_value(Map.get(values, "limit")),
         true <- limit > 0,
         {:ok, remaining} <- integer_value(Map.get(values, "remaining")),
         {:ok, reset_unix} <- integer_value(Map.get(values, "reset")),
         {:ok, reset_at} <- DateTime.from_unix(reset_unix) do
      %{resource: resource, limit: limit, remaining: remaining |> max(0) |> min(limit), reset_at: reset_at, observed_at: now}
    else
      _invalid -> nil
    end
  end

  @spec maybe_alert(map()) :: map()
  def maybe_alert(state) do
    Enum.reduce(state.windows, state, fn {resource, window}, acc ->
      cond do
        window.remaining == 0 -> emit_threshold_alert(acc, resource, window, :exhausted)
        below_floor?(window, @low_water_percent) -> emit_threshold_alert(acc, resource, window, :low)
        true -> acc
      end
    end)
  end

  # The latch is keyed on the condition, not on the window instance. Keying it
  # on `reset_at` made an hourly window rollover look like the condition
  # clearing, so every rollover emitted a `.resolved` for an exhaustion that had
  # never actually cleared and then immediately re-latched under the new reset.
  defp emit_threshold_alert(state, resource, window, threshold) do
    key = {resource, threshold}

    if MapSet.member?(state.alerts, key) do
      state
    else
      topic = alert_topic(resource, threshold)
      reset = DateTime.to_iso8601(window.reset_at)
      message = "GitHub #{resource} quota has #{window.remaining} of #{window.limit} requests remaining; resets at #{reset}"

      state.emit_fun.(topic,
        message: message,
        reason: message,
        severity: if(threshold == :exhausted, do: "critical", else: "warning"),
        needs_attention: true
      )

      %{state | alerts: MapSet.put(state.alerts, key)}
    end
  end

  @spec resource_status(map(), String.t(), number()) :: term()
  def resource_status(state, resource, floor_percent) do
    resource_status(state, resource, floor_percent, state.clock.())
  end

  defp resource_status(state, resource, floor_percent, now) do
    case Map.get(state.backoffs, resource) do
      %{until: until} ->
        if DateTime.compare(now, until) == :lt, do: {:hold, backoff_hold(state, resource, until)}, else: window_status(state, resource, floor_percent, now)

      nil ->
        window_status(state, resource, floor_percent, now)
    end
  end

  defp window_status(state, resource, floor_percent, now) do
    case Map.get(state.windows, resource) do
      %{reset_at: reset_at} = window ->
        if DateTime.compare(now, reset_at) == :lt and below_floor?(window, floor_percent) do
          {:hold, Map.take(window, [:resource, :remaining, :limit, :reset_at, :observed_at])}
        else
          :available
        end

      nil ->
        :available
    end
  end

  # A secondary limit says nothing about the primary budget, so the hold
  # reports the window's real counters when one has been observed and simply
  # substitutes the backoff deadline for the reset. Callers only need to know
  # they must not call until then.
  defp backoff_hold(state, resource, until) do
    case Map.get(state.windows, resource) do
      %{limit: limit, remaining: remaining, observed_at: observed_at} ->
        %{resource: resource, remaining: remaining, limit: limit, reset_at: until, observed_at: observed_at}

      nil ->
        %{resource: resource, remaining: 0, limit: 1, reset_at: until, observed_at: state.clock.()}
    end
  end

  @spec dispatch_status(map(), DateTime.t()) :: term()
  def dispatch_status(state, now) do
    Enum.find_value(@primary_resources, :available, fn resource ->
      case window_status(state, resource, @low_water_percent, now) do
        :available -> nil
        hold -> hold
      end
    end)
  end

  # Retry-After or explicit secondary/abuse wording identifies the short-lived
  # limiter independently of the primary remaining header. Keep it as a bounded
  # resource backoff rather than converting it into a primary window.
  @spec observe_rejection(map(), map(), term(), DateTime.t()) :: map()
  def observe_rejection(state, request, {:ok, %{status: status} = response}, now) when status in [403, 429] do
    if rate_limit_endpoint?(request) or not GraphQLErrors.secondary_rate_limited_response?(response) do
      state
    else
      put_backoff(state, request_resource(request), backoff_until(response, now), now)
    end
  end

  def observe_rejection(state, _request, _result, _now), do: state

  # Only `Retry-After` describes a secondary limit. The `x-ratelimit-reset` on
  # the same response belongs to the primary window — often an hour out — and
  # using it would park the fleet far longer than the limit actually lasts.
  defp backoff_until(response, now) do
    seconds =
      case GraphQLErrors.retry_after(response) do
        seconds when is_integer(seconds) and seconds > 0 -> min(seconds, @max_secondary_backoff_seconds)
        _absent -> @secondary_backoff_seconds
      end

    DateTime.add(now, seconds, :second)
  end

  defp put_backoff(state, resource, until, now) do
    case Map.get(state.backoffs, resource) do
      %{until: current} when current != nil ->
        if DateTime.compare(current, until) == :lt, do: store_backoff(state, resource, until, now), else: state

      nil ->
        store_backoff(state, resource, until, now)
    end
  end

  defp store_backoff(state, resource, until, now) do
    message =
      "GitHub #{resource} hit a secondary rate limit; holding all calls until #{DateTime.to_iso8601(until)} (#{DateTime.diff(until, now, :second)}s)"

    state.emit_fun.(secondary_topic(resource),
      message: message,
      reason: message,
      severity: "warning",
      needs_attention: true
    )

    %{state | backoffs: Map.put(state.backoffs, resource, %{resource: resource, until: until, observed_at: now})}
    |> write_hold_file("#{resource}-secondary-hold", DateTime.to_unix(until))
  end

  @spec prune_backoffs(map(), DateTime.t()) :: map()
  def prune_backoffs(state, now) do
    Enum.reduce(state.backoffs, state, fn {resource, backoff}, acc ->
      if DateTime.compare(now, backoff.until) == :lt do
        acc
      else
        message = "GitHub #{resource} secondary rate-limit backoff cleared"

        acc.emit_fun.(secondary_topic(resource) <> ".resolved",
          message: message,
          reason: message,
          severity: "info",
          needs_attention: false
        )

        %{acc | backoffs: Map.delete(acc.backoffs, resource)}
        |> remove_hold_file("#{resource}-secondary-hold")
      end
    end)
  end

  @spec present_backoffs(map(), DateTime.t()) :: [map()]
  def present_backoffs(state, now) do
    state.backoffs
    |> Enum.map(fn {resource, backoff} ->
      %{resource: resource, until: backoff.until, seconds_remaining: max(DateTime.diff(backoff.until, now, :second), 0)}
    end)
    |> Enum.sort_by(& &1.resource)
  end

  defp secondary_topic(resource), do: "system.github.quota.#{resource}.secondary"

  @spec default_hold_dir() :: String.t() | nil
  def default_hold_dir do
    Settings.current().quota_dir
  rescue
    _unavailable -> nil
  end

  @spec request_resource(map()) :: String.t()
  def request_resource(%{anonymous: true}), do: @anonymous_resource

  def request_resource(%{url: url}) when is_binary(url) do
    if URI.parse(url).path == "/graphql", do: "graphql", else: "core"
  end

  def request_resource(_request), do: "core"

  @spec present_window(map()) :: map()
  def present_window(window) do
    used = window.limit - window.remaining

    Map.merge(window, %{
      remaining_percent: percent(window.remaining, window.limit),
      used: used,
      used_percent: percent(used, window.limit)
    })
  end

  @spec rate_limit_endpoint?(map()) :: boolean()
  def rate_limit_endpoint?(%{url: url}) when is_binary(url), do: EndpointPolicy.free_endpoint?(url)
  def rate_limit_endpoint?(_request), do: false

  defp integer_value(value) when is_integer(value), do: {:ok, value}

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _invalid -> :error
    end
  end

  defp integer_value(_value), do: :error

  defp percent(value, limit), do: Float.round(value / limit * 100, 1)

  defp below_floor?(window, floor_percent), do: window.remaining * 100 <= window.limit * floor_percent

  defp reconcile_resource_alerts(state, resource, window) do
    Enum.reduce(state.alerts, state, fn
      {^resource, threshold} = key, acc ->
        if threshold_active?(window, threshold) do
          acc
        else
          message = "GitHub #{resource} #{threshold} quota alert cleared; #{window.remaining} of #{window.limit} requests remain"

          acc.emit_fun.(alert_topic(resource, threshold) <> ".resolved",
            message: message,
            reason: message,
            severity: "info",
            needs_attention: false
          )

          %{acc | alerts: MapSet.delete(acc.alerts, key)}
        end

      _other_key, acc ->
        acc
    end)
  end

  defp threshold_active?(%{remaining: 0}, :exhausted), do: true
  defp threshold_active?(%{remaining: remaining} = window, :low) when remaining > 0, do: below_floor?(window, @low_water_percent)
  defp threshold_active?(_window, _threshold), do: false

  defp alert_topic(resource, threshold), do: "system.github.quota.#{resource}.#{threshold}"

  defp sync_hold_file(state, resource, window) do
    if window.remaining == 0 and DateTime.compare(state.clock.(), window.reset_at) == :lt do
      write_hold_file(state, "#{resource}-hold", DateTime.to_unix(window.reset_at))
    else
      remove_hold_file(state, "#{resource}-hold")
    end
  end

  defp write_hold_file(%{hold_dir: nil} = state, _name, _unix), do: state

  defp write_hold_file(state, name, unix) do
    path = Path.join(state.hold_dir, name)
    :ok = File.mkdir_p(state.hold_dir)
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"
    :ok = File.write(temporary, Integer.to_string(unix) <> "\n")
    :ok = File.rename(temporary, path)
    state
  rescue
    _unavailable -> state
  end

  defp remove_hold_file(%{hold_dir: nil} = state, _name), do: state

  defp remove_hold_file(state, name) do
    _ = File.rm(Path.join(state.hold_dir, name))
    state
  rescue
    _unavailable -> state
  end
end
