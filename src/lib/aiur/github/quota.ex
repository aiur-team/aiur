defmodule Aiur.GitHub.Quota do
  @moduledoc """
  Fleet-wide view of the primary GitHub API budgets used by Aiur.

  GitHub returns an authoritative budget snapshot on every API response. This
  process retains those snapshots, rejects requests against an exhausted
  resource until its reset, sheds new dispatch at the low-water floor, and
  keeps coarse rolling attribution for the shared credential.

  Attribution is kept in the same unit and over the same span the meter
  reports, because a ranking that does not reconcile with the budget beside it
  names the wrong leader (#1805):

    * GraphQL bills *points*, not calls. A catalog query costing 26 points and
      a one-point read are both "one request", so a request-count ranking is
      blind to the queries that actually drain the budget. Each observation
      carries the cost the response reported in `rateLimit { cost }` where the
      query asked for it, and one point where it did not.
    * The span is the live quota window (`reset_at - 1h`), not a rolling hour,
      so the attributed span and the meter's `used` count the same calls.
    * Coverage is published alongside the ranking. Aiur cannot see every call
      billed to the credential, and an unmeasured majority presented as a
      leader invites acting on 0.04% of the spend, so the snapshot states what
      share of the window's real spend the ranking accounts for.

  The primary windows are not the only way GitHub refuses a call. Secondary
  (abuse) rate limits reject with `403`/`429` while `x-ratelimit-remaining`
  still reads healthy, so nothing in the primary windows records the refusal
  and the caller is free to retry straight into another rejection. Those
  rejections are tracked separately as a per-resource backoff honouring
  `Retry-After`, which holds callers off exactly as an exhausted window does.
  """

  use GenServer

  alias Aiur.{Alerts, Config}
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.GitHub.EndpointPolicy
  alias Aiur.GitHub.GraphQLCost
  alias Aiur.GitHub.GraphQLErrors
  alias Aiur.GitHub.RequestLog
  alias Aiur.GitHub.RequestOrigin
  alias Aiur.GitHub.Transport
  alias Aiur.RepoBase
  alias Aiur.Workspace.Layout

  @primary_resources ~w(core graphql)
  # Anonymous reads bill the 60/hr unauthenticated IP allowance, not the
  # authenticated core budget. They get their own window so an exhausted
  # anonymous allowance stays visible without gating fleet dispatch, and so a
  # `limit: 60` response can never overwrite the authenticated `core` window.
  @anonymous_resource "core:anonymous"
  @metered_resources [@anonymous_resource | @primary_resources]
  @low_water_percent 10.0
  @attribution_window_seconds 60 * 60
  # Both primary GitHub budgets run on a one-hour window, so the window that
  # a `reset_at` closes opened an hour before it.
  @quota_window_seconds 60 * 60
  @refresh_interval_ms 60_000
  @shell_refresh_interval_seconds 60
  @unattributed "unattributed"
  @agent_shell_caller "agent-shell:gh"
  # How far the per-caller breakdown may sit from what GitHub says the window
  # actually cost before it stops being evidence. Aiur cannot see calls made on
  # the credential outside this process, so a shortfall is expected; the margin
  # is what turns "roughly agrees" into a testable claim.
  @reconciliation_margin 0.05
  # The shortest window slice a per-hour rate may be extrapolated from. One
  # second of evidence multiplied by 3,600 is not a rate, it is an artefact.
  @min_rate_sample_seconds 60

  # GitHub does not always say how long a secondary limit lasts. Its own
  # guidance is to wait at least a minute, and the ceiling keeps a hostile or
  # malformed `Retry-After` from parking the whole fleet for hours.
  @secondary_backoff_seconds 60
  @max_secondary_backoff_seconds 60 * 60

  @empty_coverage %{resources: %{}, estimated?: false}
  @unknown_snapshot %{
    state: :unknown,
    windows: %{},
    attribution: [],
    callers: [],
    coverage: @empty_coverage,
    reconciliation: %{},
    backoffs: []
  }

  @type request :: map()
  @type hold :: %{
          resource: String.t(),
          remaining: non_neg_integer(),
          limit: pos_integer(),
          reset_at: DateTime.t(),
          observed_at: DateTime.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @spec observe(GenServer.server(), request(), {:ok, map()} | {:error, term()}) :: :ok
  def observe(server \\ __MODULE__, request, result) do
    GenServer.cast(server, {:observe, RequestOrigin.mark(request), result})
  catch
    :exit, _reason -> :ok
  end

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__) do
    snapshot!(server)
  catch
    :exit, _reason -> @unknown_snapshot
  end

  @doc """
  Reads the quota meter without replacing an unavailable process with an
  unknown snapshot.

  Diagnostic callers use this form when an unreachable meter must be reported
  as an error rather than presented as an empty measurement.
  """
  @spec snapshot!(GenServer.server()) :: map()
  def snapshot!(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @spec preflight(GenServer.server(), request()) :: :ok | {:hold, hold()}
  def preflight(server \\ __MODULE__, request) do
    GenServer.call(server, {:preflight, request})
  catch
    :exit, _reason -> :ok
  end

  @spec dispatch_status(GenServer.server()) :: :available | {:hold, hold()}
  def dispatch_status(server \\ __MODULE__) do
    GenServer.call(server, :dispatch_status)
  catch
    :exit, _reason -> :available
  end

  @doc false
  # Forces the durable request log's delayed-write buffer to disk, so a caller
  # that observed through the public path can read its own rows
  # deterministically (the request-log mutation test relies on this).
  @spec flush_request_log(GenServer.server()) :: :ok
  def flush_request_log(server \\ __MODULE__) do
    GenServer.call(server, :flush_request_log)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    refresh? = Keyword.get(opts, :refresh?, Application.get_env(:aiur, :github_quota_refresh?, true))

    # Resolved once at boot: every observe appends to the same durable file,
    # and re-resolving `GitHub.Config.repo()` per request would add a config
    # read to the hot path. An explicit `nil` disables the log (tests); an
    # absent value resolves the configured default.
    request_log_path =
      case Keyword.fetch(opts, :request_log_path) do
        {:ok, nil} -> nil
        {:ok, path} -> path
        :error -> RequestLog.default_path()
      end

    state = %{
      windows: %{},
      backoffs: %{},
      observations: [],
      shell_observations: [],
      shell_refreshed_at: nil,
      alerts: MapSet.new(),
      # When this meter started observing. Attribution lives in this process's
      # memory and does not survive a restart, while the credential's window
      # does — GitHub keeps counting across the restart and `/rate_limit`
      # reports the whole hour on the next refresh. Without this, a consumer
      # cannot tell "nobody else spent it" from "I was not running when it was
      # spent", and would attribute the daemon's own forgotten calls to
      # somebody else.
      # Overridable so a test can place the boot before or after a window's
      # start without also moving the clock that prices everything else.
      started_at: Keyword.get_lazy(opts, :started_at, fn -> Keyword.get(opts, :clock, &DateTime.utc_now/0).() end),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      emit_fun: Keyword.get(opts, :emit_fun, &Alerts.emit_system/2),
      shell_log_path: Keyword.get_lazy(opts, :shell_log_path, &default_shell_log_path/0),
      hold_dir: Keyword.get_lazy(opts, :hold_dir, &default_hold_dir/0),
      request_log_path: request_log_path,
      # The durable request log's io_device, opened once here in
      # `:delayed_write` and closed on terminate (#2255). Holding it keeps an
      # observe from paying an open/close/stat on this GenServer's message
      # loop, which gates every agent's GitHub access.
      request_log_io: RequestLog.open_writer(request_log_path),
      # Bytes written to the current file, tracked so rotation happens at the
      # cap without a `stat` per request.
      request_log_bytes: 0,
      refresh_fun: Keyword.get(opts, :refresh_fun, &refresh_from_github/0),
      recovery_fun: Keyword.get(opts, :recovery_fun, &notify_orchestrator_recovery/0),
      observed_dispatch_hold?: false,
      recovery_timer_ref: nil,
      recovery_timer_token: nil,
      refresh_interval_ms: Keyword.get(opts, :refresh_interval_ms, @refresh_interval_ms),
      refresh_ref: nil
    }

    if refresh?, do: Process.send_after(self(), :refresh, 0)
    {:ok, state}
  end

  @impl true
  def handle_cast({:observe, request, result}, state) do
    now = state.clock.()
    held_before? = state.observed_dispatch_hold?

    # Durable per-request record (#2255). Every request routed through this
    # chokepoint lands one row in `daemon-requests.tsv` — timestamp, pid,
    # caller, method, path/operation, status, cost, credential fingerprint —
    # so a budget question is answerable from logs alone after the window has
    # closed. It runs for every observe (including `/rate_limit` probes) and
    # is deliberately independent of the in-memory attribution below: the log
    # is the evidence, the attribution is the ranking.
    state =
      state
      |> log_request(request, result, now)
      |> prune_backoffs(now)
      |> observe_response(request, result, now)
      |> observe_rejection(request, result, now)
      |> attribute_request(request, result, now)
      |> maybe_alert()

    status = dispatch_status(state, now)
    held_now? = match?({:hold, _hold}, status)
    if held_before? and not held_now?, do: state.recovery_fun.()

    state = state |> Map.put(:observed_dispatch_hold?, held_now?) |> sync_recovery_timer(status, now)
    {:noreply, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    now = state.clock.()
    state = state |> prune_backoffs(now) |> prune_observations(now) |> refresh_shell_observations(now)

    in_window = observations_in_window(state, now)

    coverage = coverage(in_window, state.windows, now)

    snapshot = %{
      state: if(map_size(state.windows) == 0, do: :unknown, else: :observed),
      windows:
        Map.new(state.windows, fn {resource, window} ->
          {resource, window |> present_window() |> Map.put(:started_at, window_start(state.windows, resource, now))}
        end),
      observing_since: observing_since(state, now),
      attribution: summarize_attribution(in_window),
      callers: summarize_callers(in_window, state.windows, now),
      coverage: coverage,
      reconciliation: reconciliation(coverage),
      backoffs: present_backoffs(state, now)
    }

    {:reply, snapshot, state}
  end

  def handle_call({:preflight, request}, _from, state) do
    state = prune_backoffs(state, state.clock.())

    reply =
      if rate_limit_endpoint?(request) do
        :ok
      else
        case resource_status(state, request_resource(request), 0.0) do
          :available -> :ok
          hold -> hold
        end
      end

    {:reply, reply, state}
  end

  def handle_call(:dispatch_status, _from, state) do
    now = state.clock.()
    state = prune_backoffs(state, now)
    {:reply, dispatch_status(state, now), state}
  end

  def handle_call(:flush_request_log, _from, state) do
    reply =
      case state.request_log_io do
        nil -> :ok
        io -> RequestLog.sync(io)
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:refresh, %{refresh_ref: nil} = state) do
    refresh_fun = state.refresh_fun
    {_pid, ref} = spawn_monitor(refresh_fun)
    {:noreply, %{state | refresh_ref: ref}}
  end

  def handle_info(:refresh, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{refresh_ref: ref} = state) do
    Process.send_after(self(), :refresh, state.refresh_interval_ms)
    {:noreply, %{state | refresh_ref: nil}}
  end

  def handle_info({:dispatch_recovery, token}, %{recovery_timer_token: token} = state) do
    now = state.clock.()
    state = prune_backoffs(state, now)
    status = dispatch_status(state, now)
    held_now? = match?({:hold, _hold}, status)

    if state.observed_dispatch_hold? and not held_now?, do: state.recovery_fun.()

    state = state |> Map.put(:observed_dispatch_hold?, held_now?) |> sync_recovery_timer(status, now)
    {:noreply, state}
  end

  def handle_info({:dispatch_recovery, _stale_token}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Flush and close the request log's delayed-write io_device so the last
    # buffered rows are not lost on shutdown.
    if state.request_log_io, do: :file.close(state.request_log_io)
    :ok
  end

  defp observe_response(state, _request, {:ok, %{body: %{"resources" => resources}}}, now) when is_map(resources) do
    Enum.reduce(@primary_resources, state, fn resource, acc ->
      case Map.get(resources, resource) do
        %{} = values -> put_window_from_values(acc, resource, values, now)
        _missing -> acc
      end
    end)
  end

  # Successful instrumented GraphQL responses report `rateLimit { limit
  # remaining resetAt }` in their body. Secondary-limit responses are excluded
  # before window ingestion because their headers do not establish primary
  # exhaustion.
  defp observe_response(state, request, {:ok, response}, now) when is_map(response) do
    if GraphQLErrors.secondary_rate_limited_response?(response) do
      state
    else
      case graphql_rate_limit_values(request, response) do
        %{} = values -> put_window_from_values(state, "graphql", values, now)
        nil -> observe_response_headers(state, request, response, now)
      end
    end
  end

  defp observe_response(state, _request, _result, _now), do: state

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

    if resource in @metered_resources do
      values = %{
        "limit" => Transport.header(headers, "x-ratelimit-limit"),
        "remaining" => Transport.header(headers, "x-ratelimit-remaining"),
        "reset" => Transport.header(headers, "x-ratelimit-reset")
      }

      put_window_from_values(state, resource, values, now)
    else
      state
    end
  end

  defp put_window_from_values(state, resource, values, now) do
    with {:ok, limit} <- integer_value(Map.get(values, "limit")),
         true <- limit > 0,
         {:ok, remaining} <- integer_value(Map.get(values, "remaining")),
         {:ok, reset_unix} <- integer_value(Map.get(values, "reset")),
         {:ok, reset_at} <- DateTime.from_unix(reset_unix) do
      remaining = remaining |> max(0) |> min(limit)

      window = %{
        resource: resource,
        limit: limit,
        remaining: remaining,
        reset_at: reset_at,
        observed_at: now
      }

      state
      |> Map.put(:windows, Map.put(state.windows, resource, window))
      |> reconcile_resource_alerts(resource, window)
      |> sync_hold_file(resource, window)
    else
      _invalid -> state
    end
  end

  defp maybe_alert(state) do
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

  defp resource_status(state, resource, floor_percent) do
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

  defp dispatch_status(state, now) do
    Enum.find_value(@primary_resources, :available, fn resource ->
      case window_status(state, resource, @low_water_percent, now) do
        :available -> nil
        hold -> hold
      end
    end)
  end

  defp sync_recovery_timer(state, :available, _now) do
    cancel_recovery_timer(state)
    %{state | recovery_timer_ref: nil, recovery_timer_token: nil}
  end

  defp sync_recovery_timer(state, {:hold, %{reset_at: reset_at}}, now) do
    cancel_recovery_timer(state)
    token = make_ref()
    delay_ms = max(DateTime.diff(reset_at, now, :millisecond), 0)
    timer_ref = Process.send_after(self(), {:dispatch_recovery, token}, delay_ms)
    %{state | recovery_timer_ref: timer_ref, recovery_timer_token: token}
  end

  defp cancel_recovery_timer(%{recovery_timer_ref: ref}) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_recovery_timer(_state), do: false

  # Retry-After or explicit secondary/abuse wording identifies the short-lived
  # limiter independently of the primary remaining header. Keep it as a bounded
  # resource backoff rather than converting it into a primary window.
  defp observe_rejection(state, request, {:ok, %{status: status} = response}, now) when status in [403, 429] do
    if rate_limit_endpoint?(request) or not GraphQLErrors.secondary_rate_limited_response?(response) do
      state
    else
      put_backoff(state, request_resource(request), backoff_until(response, now), now)
    end
  end

  defp observe_rejection(state, _request, _result, _now), do: state

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

  defp prune_backoffs(state, now) do
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

  defp present_backoffs(state, now) do
    state.backoffs
    |> Enum.map(fn {resource, backoff} ->
      %{resource: resource, until: backoff.until, seconds_remaining: max(DateTime.diff(backoff.until, now, :second), 0)}
    end)
    |> Enum.sort_by(& &1.resource)
  end

  defp secondary_topic(resource), do: "system.github.quota.#{resource}.secondary"

  defp attribute_request(state, request, result, now) do
    if rate_limit_endpoint?(request) do
      state
    else
      resource = request_resource(request)
      {status, response} = attribution_response(result)
      {cost, cost_source} = request_cost(resource, status, response)

      observation = %{
        consumer: request_consumer(request),
        caller: GraphQLCost.derive(request),
        view_originated?: Map.get(request, :view_originated?, false) == true,
        direction: request_direction(request),
        resource: resource,
        cost: cost,
        cost_source: cost_source,
        observed_at: now
      }

      prune_observations(%{state | observations: [observation | state.observations]}, now)
    end
  end

  defp attribution_response({:ok, response}) when is_map(response), do: {Map.get(response, :status), response}
  defp attribution_response(_result), do: {nil, %{}}

  # What the call actually cost the budget it was billed to.
  #
  # A `304` is served from GitHub's cache and is not billed at all, so counting
  # it would attribute spend that never happened. Core bills one request per
  # call. GraphQL bills points: only the response body reports what the query
  # spent, and it reports it only where the query asked for `rateLimit { cost }`
  # (#1766). A query that did not ask is recorded at one point and marked
  # estimated, which understates it — the coverage figure is what keeps that
  # understatement visible instead of silently flattering the ranking.
  defp request_cost(_resource, 304, _response), do: {0, :reported}

  defp request_cost("graphql", _status, response) do
    case GraphQLCost.reported(response) do
      %{cost: cost} when is_integer(cost) and cost >= 0 -> {cost, :reported}
      _unreported -> {1, :assumed}
    end
  end

  defp request_cost(_resource, _status, _response), do: {1, :reported}

  # Durable per-request record. Written through the io_device held in state,
  # so an observe never pays an open/close/stat on this message loop. Rotation
  # is driven by the byte count tracked here; a failed write (disk full, io
  # error) drops the device and later observes skip the log rather than retry
  # a dead device or take this GenServer down.
  defp log_request(state, request, result, now) do
    case state.request_log_io do
      nil ->
        state

      io ->
        case RequestLog.append_io(io, request, result, now) do
          {:ok, bytes} -> account_request_log_bytes(state, bytes)
          {:error, _reason} -> %{state | request_log_io: nil, request_log_bytes: 0}
        end
    end
  end

  # Tracks bytes written to the current file and rotates at the cap without a
  # `stat` per request.
  defp account_request_log_bytes(state, bytes) do
    total = state.request_log_bytes + bytes

    if total > RequestLog.max_bytes() do
      rotate_request_log(state)
    else
      %{state | request_log_bytes: total}
    end
  end

  defp rotate_request_log(state) do
    if state.request_log_io, do: :file.close(state.request_log_io)
    RequestLog.rotate(state.request_log_path)
    %{state | request_log_io: RequestLog.open_writer(state.request_log_path), request_log_bytes: 0}
  end

  defp prune_observations(state, now) do
    cutoff = DateTime.add(now, -@attribution_window_seconds, :second)
    %{state | observations: Enum.filter(state.observations, &(DateTime.compare(&1.observed_at, cutoff) != :lt))}
  end

  # The meter counts the live quota window, which opened an hour before its
  # reset — a rolling hour of attribution would summarize a different span than
  # the number printed beside it. Where no window has been observed for a
  # resource there is nothing to reconcile against, and the rolling hour is the
  # honest fallback.
  defp observations_in_window(state, now) do
    starts = Map.new(@primary_resources, &{&1, window_start(state.windows, &1, now)})
    Enum.filter(state.observations ++ state.shell_observations, &within_window?(&1, starts, now))
  end

  defp window_start(windows, resource, now) do
    case Map.get(windows, resource) do
      %{reset_at: reset_at} ->
        if DateTime.compare(now, reset_at) == :lt,
          do: DateTime.add(reset_at, -@quota_window_seconds, :second),
          else: rolling_start(now)

      _unobserved ->
        rolling_start(now)
    end
  end

  defp rolling_start(now), do: DateTime.add(now, -@attribution_window_seconds, :second)

  @doc """
  The earliest moment this meter could have attributed a call.

  Not "when the first call happened" — a daemon that has been up for hours and
  was simply idle for the first ten minutes of a window can still account for
  the whole window. This is the boundary of what the meter is *able* to have
  seen: its own boot, or the edge of the rolling attribution window, whichever
  is later.

  A consumer compares this against a window's `started_at` to know whether the
  shortfall between `attributed` and `spend` means "another consumer spent it"
  or only "I was not running yet". The two are different facts and only one of
  them names somebody else.
  """
  @spec observing_since(map(), DateTime.t()) :: DateTime.t()
  def observing_since(%{started_at: %DateTime{} = started_at}, now) do
    rolling = rolling_start(now)
    if DateTime.compare(started_at, rolling) == :gt, do: started_at, else: rolling
  end

  def observing_since(_state, now), do: rolling_start(now)

  defp within_window?(observation, starts, now) do
    start = Map.get(starts, observation_resource(observation)) || rolling_start(now)
    DateTime.compare(observation.observed_at, start) != :lt
  end

  # Agent-shell rows written before the resource column existed, and any row
  # naming a resource Aiur does not meter, are counted against core: `gh` spends
  # the core budget on everything but `api graphql`.
  defp observation_resource(%{resource: resource}) when resource in @metered_resources, do: resource
  defp observation_resource(_observation), do: "core"

  defp summarize_attribution(observations) do
    observations
    |> Enum.group_by(& &1.consumer)
    |> Enum.map(fn {consumer, entries} ->
      reads = Enum.count(entries, &(&1.direction == :read))

      %{
        consumer: consumer,
        reads: reads,
        writes: length(entries) - reads,
        total: length(entries),
        cost: total_cost(entries),
        costs: costs_by_resource(entries),
        estimated?: estimated?(entries)
      }
    end)
    |> Enum.sort_by(&{-&1.cost, -&1.total, &1.consumer})
  end

  # Points per hour by call site, ranked, for one budget's live window.
  #
  # This is the answer to "where does the budget go", and it is deliberately a
  # different question from `summarize_attribution/1`'s "which ticket is
  # expensive". A batch query names 33 tickets and belongs to one poller; ranking
  # it by ticket splits its cost 33 ways and hides it under the noise floor.
  #
  # The rate is extrapolated from the elapsed part of the window, not the whole
  # hour, so a caller measured 6 minutes into a window reports the per-hour rate
  # it is *running at* rather than a tenth of it. That is the figure that compares
  # against the 5,000/hour ceiling, which is the only comparison anyone makes
  # here: the daemon's measured ~250 points/minute is only alarming once it is
  # stated as ~15,000/hour against 5,000.
  defp summarize_callers(observations, windows, now) do
    observations
    |> Enum.group_by(&{observation_resource(&1), Map.get(&1, :caller) || @unattributed})
    |> Enum.map(fn {{resource, caller}, entries} ->
      points = total_cost(entries)
      reads = Enum.count(entries, &(&1.direction == :read))
      elapsed = elapsed_seconds(windows, resource, now)

      %{
        caller: caller,
        resource: resource,
        calls: length(entries),
        view_calls: Enum.count(entries, &(Map.get(&1, :view_originated?, false) == true)),
        reads: reads,
        writes: length(entries) - reads,
        points: points,
        points_per_hour: per_hour(points, elapsed),
        elapsed_seconds: elapsed,
        estimated?: estimated?(entries)
      }
    end)
    |> Enum.sort_by(&{&1.resource, -&1.points, -&1.calls, &1.caller})
  end

  # An hour of window has not necessarily elapsed. Dividing by a full hour
  # regardless would report a caller burning the budget in ten minutes as if it
  # were spending at a sixth of its real rate — an understatement precisely
  # where the number matters most.
  defp elapsed_seconds(windows, resource, now) do
    start = window_start(windows, resource, now)
    now |> DateTime.diff(start, :second) |> max(0) |> min(@quota_window_seconds)
  end

  # Below the minimum sample the rate is unknown rather than enormous. One point
  # observed one second into a fresh window extrapolates to 3,600/hour, which
  # would rank a trivial call above the real leader and be printed against the
  # 5,000 ceiling as if it meant something.
  defp per_hour(points, elapsed) when is_integer(points) and is_integer(elapsed) and elapsed >= @min_rate_sample_seconds,
    do: Float.round(points * 3600 / elapsed, 1)

  defp per_hour(_points, _elapsed), do: nil

  @doc """
  Does the per-caller breakdown add up to what GitHub says the window cost?

  A breakdown that does not reconcile is not evidence, it is a guess with a
  table around it. `spend` is `limit - remaining` from the credential's own
  `/rate_limit` window — the number the operator sees drop — and `attributed`
  is the sum of every row in the ranking. `reconciled?` is the claim that the
  two agree closely enough to act on.

  The two ways it can fail are not the same fact, so `direction` separates them:

    * `:shortfall` — Aiur attributed less than the window spent. This is the
      normal, expected case: calls made on the same credential by anything
      outside this process are real spend Aiur never saw. It bounds how much of
      the ranking is the whole story; it is not a defect.
    * `:excess` — Aiur attributed more than the window spent. Points cannot be
      counted twice, so this is a bug in the accounting and is the only case
      worth alarming on.
    * `:agrees` — inside the margin.

  Collapsing both into one boolean would print an alarm during normal operation,
  and an operator who learns to ignore the alarm cannot see the double count
  when it happens. `reconciled?` is kept for the inside-the-margin claim.
  """
  @spec reconciliation(map()) :: %{optional(String.t()) => map()}
  def reconciliation(%{resources: resources}) when is_map(resources) do
    Map.new(resources, fn {resource, figures} ->
      attributed = Map.get(figures, :attributed)
      spend = Map.get(figures, :spend)

      {resource,
       %{
         attributed: attributed,
         spend: spend,
         delta: delta(attributed, spend),
         margin: @reconciliation_margin,
         reconciled?: reconciled?(attributed, spend),
         direction: direction(attributed, spend),
         estimated?: Map.get(figures, :estimated?, false)
       }}
    end)
  end

  def reconciliation(_coverage), do: %{}

  defp delta(attributed, spend) when is_integer(attributed) and is_integer(spend), do: attributed - spend
  defp delta(_attributed, _spend), do: nil

  # Nothing spent is trivially reconciled; nothing observed is not reconciled,
  # it is unmeasured, and saying so is the difference between the two.
  defp reconciled?(attributed, spend) when is_integer(attributed) and is_integer(spend) and spend > 0,
    do: abs(attributed - spend) / spend <= @reconciliation_margin

  defp reconciled?(attributed, 0) when is_integer(attributed), do: attributed == 0
  defp reconciled?(_attributed, _spend), do: nil

  defp direction(attributed, spend) when is_integer(attributed) and is_integer(spend) do
    cond do
      reconciled?(attributed, spend) -> :agrees
      attributed < spend -> :shortfall
      true -> :excess
    end
  end

  defp direction(_attributed, _spend), do: nil

  # What the ranking above is worth — stated per budget, never combined.
  #
  # Core bills requests and GraphQL bills points, on separate windows that reset
  # at different times. Adding the two and printing the sum would invent a
  # quantity ("4% of 10000 spent this window") that describes neither budget and
  # no single window: the same confident-wrong-number failure #1805 reported,
  # committed by the sentence that claims to quantify honesty. So there is no
  # combined figure to render by accident. Each budget carries `attributed`
  # (every call Aiur saw), `named` (only the calls it could tie to a ticket —
  # the ones the ranking can order) and `spend` (what GitHub says that window
  # actually cost).
  defp coverage(observations, windows, now) do
    %{resources: coverage_by_resource(observations, windows, now), estimated?: estimated?(observations)}
  end

  defp coverage_by_resource(observations, windows, now) do
    windows
    |> Enum.flat_map(fn {resource, window} ->
      case window_spend(window, now) do
        nil ->
          []

        spend ->
          entries = Enum.filter(observations, &(observation_resource(&1) == resource))
          named = Enum.reject(entries, &(&1.consumer == @unattributed))

          [
            {resource,
             %{
               attributed: total_cost(entries),
               named: total_cost(named),
               spend: spend,
               fraction: fraction(total_cost(entries), spend),
               named_fraction: fraction(total_cost(named), spend),
               estimated?: estimated?(entries)
             }}
          ]
      end
    end)
    |> Map.new()
  end

  # Core and GraphQL are separate budgets billed in different units, so the
  # per-consumer figure keeps them apart as well as summed: an operator asking
  # "which budget is this ticket burning" needs the split.
  defp costs_by_resource(observations) do
    observations
    |> Enum.group_by(&observation_resource/1)
    |> Map.new(fn {resource, entries} -> {resource, total_cost(entries)} end)
  end

  # A window whose reset has already passed is not the live window. Its
  # `limit - remaining` describes a span that has closed, while attribution has
  # already fallen back to the rolling hour (`window_start/3`) — so reporting
  # one against the other would state a coverage figure "this window" for a
  # window that no longer exists, over calls it never contained. The resource
  # reports no coverage at all until GitHub is observed again.
  defp window_spend(%{limit: limit, remaining: remaining, reset_at: %DateTime{} = reset_at}, now) do
    if DateTime.compare(now, reset_at) == :lt, do: max(limit - remaining, 0), else: nil
  end

  defp window_spend(_window, _now), do: nil

  defp total_cost(observations), do: Enum.reduce(observations, 0, &(observation_cost(&1) + &2))

  defp observation_cost(%{cost: cost}) when is_integer(cost) and cost >= 0, do: cost
  defp observation_cost(_observation), do: 1

  defp estimated?(observations), do: Enum.any?(observations, &(Map.get(&1, :cost_source) == :assumed))

  # A window can report more spend than Aiur attributed, never less that means
  # anything: clamping keeps a stale or double-counted observation from
  # claiming above-total coverage.
  defp fraction(_attributed, spend) when not is_integer(spend) or spend <= 0, do: nil
  defp fraction(attributed, spend), do: Float.round(min(attributed / spend, 1.0), 4)

  defp refresh_shell_observations(%{shell_refreshed_at: %DateTime{} = refreshed_at} = state, now) do
    if DateTime.diff(now, refreshed_at, :second) < @shell_refresh_interval_seconds do
      state
    else
      load_shell_observations(state, now)
    end
  end

  defp refresh_shell_observations(state, now), do: load_shell_observations(state, now)

  defp load_shell_observations(state, now) do
    %{state | shell_observations: shell_observations(state.shell_log_path, now), shell_refreshed_at: now}
  end

  defp shell_observations(nil, _now), do: []

  defp shell_observations(path, now) when is_binary(path) do
    cutoff = DateTime.add(now, -@attribution_window_seconds, :second)

    # `match_dot: true` is mandatory, not defensive: the log lives under each
    # workspace's `.aiur-runtime/`, and without it `Path.wildcard/1` refuses to
    # descend through a dot directory and silently matches nothing. Together
    # with the unexpanded `~` above, that left every agent `gh` call outside
    # attribution while the meter still billed them (#1805).
    [path <> ".1", path]
    |> Enum.flat_map(&Path.wildcard(&1, match_dot: true))
    |> Stream.flat_map(&shell_file_lines/1)
    |> Stream.map(&parse_shell_observation/1)
    |> Stream.reject(&is_nil/1)
    |> Enum.filter(fn observation ->
      DateTime.compare(observation.observed_at, cutoff) != :lt and DateTime.compare(observation.observed_at, now) != :gt
    end)
  rescue
    _unavailable -> []
  end

  defp shell_file_lines(path) do
    case File.read(path) do
      {:ok, contents} -> String.split(contents, "\n", trim: true)
      {:error, _reason} -> []
    end
  end

  defp default_hold_dir do
    case Aiur.GitHub.Config.repo() do
      repo when is_binary(repo) and repo != "" ->
        repo
        |> RepoBase.repo_path()
        |> Path.join("github-quota")

      _unconfigured ->
        nil
    end
  rescue
    _unavailable -> nil
  end

  # The resource column was added with cost-weighted attribution; rows written
  # before it are still valid and are read as core (see `observation_resource/1`).
  # The credential fingerprint and wrapper pid columns came with #2255 so the
  # agent record answers "which pool" and names the exact subprocess; rows
  # written before them simply have no value in those columns. An agent shell
  # cannot see what a GraphQL query cost, so its rows carry one point and are
  # marked estimated rather than silently counted as exact.
  @doc false
  @spec parse_shell_observation(String.t()) :: map() | nil
  def parse_shell_observation(line) do
    with [unix, consumer, direction | rest] <- line |> String.trim() |> String.split("\t"),
         {unix, ""} <- Integer.parse(unix),
         {:ok, observed_at} <- DateTime.from_unix(unix),
         true <- direction in ["read", "write"],
         true <- consumer == @unattributed or Regex.match?(~r/^ticket:\d+$/, consumer) do
      resource = shell_resource(rest)

      %{
        consumer: consumer,
        # Every row in this file was written by the agent `gh` wrapper, so the
        # call site is known exactly even though the ticket varies. The caller
        # names that call site (`agent-shell:gh pr view`) so `github-cost` can
        # rank the agent-side spend by gh subcommand rather than folding the
        # whole fleet into one `agent-shell:gh` row (#2299). A row written
        # before the call-site column falls back to the undifferentiated name.
        caller: shell_caller(rest),
        direction: String.to_existing_atom(direction),
        resource: resource,
        cost: 1,
        cost_source: if(resource == "graphql", do: :assumed, else: :reported),
        token_key: shell_column(rest, 2),
        pid: shell_pid(rest),
        observed_at: observed_at
      }
    else
      _invalid -> nil
    end
  end

  defp shell_resource([resource | _rest]) when resource in @primary_resources, do: resource
  defp shell_resource(_columns), do: "core"

  # The fifth column is the gh subcommand the guard recorded (`pr view`, `issue
  # list`, `api graphql`, ...). Rows that predate it have no call-site column.
  # The guard allowlists the value, and the reader re-checks it: a row that
  # somehow carries a character outside the safe set (a forged spend row, say)
  # is not named — it falls back to the undifferentiated caller so an injected
  # call site can never appear as its own ranked row.
  defp shell_caller([_resource, call_site | _]) when is_binary(call_site) and call_site != "" do
    if Regex.match?(~r/\A[a-zA-Z0-9 _-]+\z/, call_site),
      do: @agent_shell_caller <> " " <> call_site,
      else: @agent_shell_caller
  end

  defp shell_caller(_columns), do: @agent_shell_caller

  # The credential fingerprint (column 6) and the wrapper pid (column 7) ride
  # after the call site so a request is attributable to its pool and to the
  # exact subprocess that made it (#2255). Rows written before either column
  # degrade to nil.
  defp shell_column(columns, index), do: Enum.at(columns, index) |> shell_blank()

  defp shell_pid(columns) do
    case Enum.at(columns, 3) do
      pid when is_binary(pid) ->
        case Integer.parse(pid) do
          {value, ""} when value > 0 -> value
          _invalid -> nil
        end

      _missing ->
        nil
    end
  end

  defp shell_blank(nil), do: nil
  defp shell_blank(""), do: nil
  defp shell_blank(value), do: value

  # `Path.wildcard/1` does not expand a leading `~`, so a configured workspace
  # root written in tilde form matched nothing and every agent-shell call went
  # uncounted while the meter still billed them (#1805).
  defp default_shell_log_path do
    Config.workspace_root()
    |> Path.expand()
    |> Layout.issue_workspace_path("__github_quota_probe__")
    |> Path.dirname()
    |> Path.join("*/.aiur-runtime/github-quota/agent-requests.tsv")
  rescue
    _unavailable -> nil
  end

  defp refresh_from_github do
    with token when is_binary(token) and token != "" <- GitHubConfig.token() do
      Transport.default_request_fun(%{
        method: :get,
        url: "https://api.github.com/rate_limit",
        token: token,
        timeout_ms: 10_000
      })
    end

    :ok
  rescue
    _unavailable -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp notify_orchestrator_recovery do
    case Process.whereis(Aiur.Orchestrator) do
      pid when is_pid(pid) -> send(pid, :github_quota_recovered)
      nil -> :ok
    end

    :ok
  end

  defp request_resource(%{anonymous: true}), do: @anonymous_resource

  defp request_resource(%{url: url}) when is_binary(url) do
    if URI.parse(url).path == "/graphql", do: "graphql", else: "core"
  end

  defp request_resource(_request), do: "core"

  defp request_direction(%{method: :post, url: url, body: %{"query" => query}}) when is_binary(url) and is_binary(query) do
    if URI.parse(url).path == "/graphql" and Regex.match?(~r/^\s*mutation\b/i, query), do: :write, else: :read
  end

  defp request_direction(%{method: method}) when method in [:get, :head], do: :read
  defp request_direction(_request), do: :write

  defp request_consumer(%{consumer: consumer}) when is_binary(consumer) and consumer != "", do: consumer

  defp request_consumer(request) do
    ticket_number_from_url(request) || ticket_number_from_variables(request) || "unattributed"
  end

  defp ticket_number_from_url(%{url: url}) when is_binary(url) do
    case Regex.run(~r{/(?:issues|pulls)/(\d+)(?:/|$)}, URI.parse(url).path || "") do
      [_, number] -> "ticket:#{number}"
      _no_ticket -> nil
    end
  end

  defp ticket_number_from_url(_request), do: nil

  defp ticket_number_from_variables(%{body: %{"variables" => variables}}) when is_map(variables) do
    variables
    |> find_ticket_number()
    |> case do
      nil -> nil
      number -> "ticket:#{number}"
    end
  end

  defp ticket_number_from_variables(_request), do: nil

  defp find_ticket_number(map) when is_map(map) do
    direct = Enum.find_value(~w(number issue_number pull_number), fn key -> valid_ticket_number(Map.get(map, key) || Map.get(map, String.to_atom(key))) end)
    direct || Enum.find_value(Map.values(map), &find_ticket_number/1)
  end

  defp find_ticket_number(list) when is_list(list), do: Enum.find_value(list, &find_ticket_number/1)
  defp find_ticket_number(_value), do: nil

  defp valid_ticket_number(number) when is_integer(number) and number > 0, do: number

  defp valid_ticket_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> parsed
      _invalid -> nil
    end
  end

  defp valid_ticket_number(_number), do: nil

  defp present_window(window) do
    used = window.limit - window.remaining

    Map.merge(window, %{
      remaining_percent: percent(window.remaining, window.limit),
      used: used,
      used_percent: percent(used, window.limit)
    })
  end

  defp rate_limit_endpoint?(%{url: url}) when is_binary(url), do: EndpointPolicy.free_endpoint?(url)
  defp rate_limit_endpoint?(_request), do: false

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
