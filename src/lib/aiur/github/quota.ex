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
  alias Aiur.GitHub.GraphQLErrors
  alias Aiur.GitHub.Transport
  alias Aiur.RepoBase
  alias Aiur.Workspace.Layout

  @primary_resources ~w(core graphql)
  @low_water_percent 10.0
  @attribution_window_seconds 60 * 60
  # Both primary GitHub budgets run on a one-hour window, so the window that
  # a `reset_at` closes opened an hour before it.
  @quota_window_seconds 60 * 60
  @refresh_interval_ms 60_000
  @shell_refresh_interval_seconds 60
  @unattributed "unattributed"

  # GitHub does not always say how long a secondary limit lasts. Its own
  # guidance is to wait at least a minute, and the ceiling keeps a hostile or
  # malformed `Retry-After` from parking the whole fleet for hours.
  @secondary_backoff_seconds 60
  @max_secondary_backoff_seconds 60 * 60

  @empty_coverage %{resources: %{}, estimated?: false}
  @unknown_snapshot %{state: :unknown, windows: %{}, attribution: [], coverage: @empty_coverage, backoffs: []}

  @type request :: map()
  @type hold :: %{resource: String.t(), remaining: non_neg_integer(), limit: pos_integer(), reset_at: DateTime.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @spec observe(GenServer.server(), request(), {:ok, map()} | {:error, term()}) :: :ok
  def observe(server \\ __MODULE__, request, result) do
    GenServer.cast(server, {:observe, request, result})
  catch
    :exit, _reason -> :ok
  end

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  catch
    :exit, _reason -> @unknown_snapshot
  end

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

  @impl true
  def init(opts) do
    refresh? = Keyword.get(opts, :refresh?, Application.get_env(:aiur, :github_quota_refresh?, true))

    state = %{
      windows: %{},
      backoffs: %{},
      observations: [],
      shell_observations: [],
      shell_refreshed_at: nil,
      alerts: MapSet.new(),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      emit_fun: Keyword.get(opts, :emit_fun, &Alerts.emit_system/2),
      shell_log_path: Keyword.get_lazy(opts, :shell_log_path, &default_shell_log_path/0),
      hold_dir: Keyword.get_lazy(opts, :hold_dir, &default_hold_dir/0),
      refresh_fun: Keyword.get(opts, :refresh_fun, &refresh_from_github/0),
      refresh_interval_ms: Keyword.get(opts, :refresh_interval_ms, @refresh_interval_ms),
      refresh_ref: nil
    }

    if refresh?, do: Process.send_after(self(), :refresh, 0)
    {:ok, state}
  end

  @impl true
  def handle_cast({:observe, request, result}, state) do
    now = state.clock.()

    state =
      state
      |> prune_backoffs(now)
      |> observe_response(result, now)
      |> observe_rejection(request, result, now)
      |> attribute_request(request, result, now)
      |> maybe_alert()

    {:noreply, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    now = state.clock.()
    state = state |> prune_backoffs(now) |> prune_observations(now) |> refresh_shell_observations(now)
    in_window = observations_in_window(state, now)

    snapshot = %{
      state: if(map_size(state.windows) == 0, do: :unknown, else: :observed),
      windows: Map.new(state.windows, fn {resource, window} -> {resource, present_window(window)} end),
      attribution: summarize_attribution(in_window),
      coverage: coverage(in_window, state.windows, now),
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
    state = prune_backoffs(state, state.clock.())

    status =
      Enum.find_value(@primary_resources, :available, fn resource ->
        case resource_status(state, resource, @low_water_percent) do
          :available -> nil
          hold -> hold
        end
      end)

    {:reply, status, state}
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

  defp observe_response(state, {:ok, %{body: %{"resources" => resources}}}, now) when is_map(resources) do
    Enum.reduce(@primary_resources, state, fn resource, acc ->
      case Map.get(resources, resource) do
        %{} = values -> put_window_from_values(acc, resource, values, now)
        _missing -> acc
      end
    end)
  end

  defp observe_response(state, {:ok, response}, now) when is_map(response) do
    headers = Map.get(response, :headers, [])
    resource = Transport.header(headers, "x-ratelimit-resource")

    if resource in @primary_resources do
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

  defp observe_response(state, _result, _now), do: state

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

  defp emit_threshold_alert(state, resource, window, threshold) do
    key = {resource, window.reset_at, threshold}

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
    now = state.clock.()

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
          {:hold, Map.take(window, [:resource, :remaining, :limit, :reset_at])}
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
      %{limit: limit, remaining: remaining} -> %{resource: resource, remaining: remaining, limit: limit, reset_at: until}
      nil -> %{resource: resource, remaining: 0, limit: 1, reset_at: until}
    end
  end

  # GitHub signals a secondary limit with a 403 or 429 whose primary window is
  # still healthy. A rejection that *did* drain the window is already covered
  # by the window hold, so only the former needs its own backoff.
  defp observe_rejection(state, request, {:ok, %{status: status} = response}, now) when status in [403, 429] do
    if rate_limit_endpoint?(request) or not secondary_limit?(response) do
      state
    else
      put_backoff(state, request_resource(request), backoff_until(response, now), now)
    end
  end

  defp observe_rejection(state, _request, _result, _now), do: state

  defp secondary_limit?(response) do
    GraphQLErrors.rate_limited_response?(response, :unknown) and GraphQLErrors.rate_limit_remaining(response) != 0
  end

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

  defp attribute_request(state, request, {:ok, %{status: status} = response}, now) when is_integer(status) do
    if rate_limit_endpoint?(request) do
      state
    else
      resource = request_resource(request)
      {cost, cost_source} = request_cost(resource, status, response)

      observation = %{
        consumer: request_consumer(request),
        direction: request_direction(request),
        resource: resource,
        cost: cost,
        cost_source: cost_source,
        observed_at: now
      }

      prune_observations(%{state | observations: [observation | state.observations]}, now)
    end
  end

  defp attribute_request(state, _request, _result, _now), do: state

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
    case graphql_reported_cost(response) do
      cost when is_integer(cost) and cost >= 0 -> {cost, :reported}
      _unreported -> {1, :assumed}
    end
  end

  defp request_cost(_resource, _status, _response), do: {1, :reported}

  defp graphql_reported_cost(%{body: %{"data" => %{"rateLimit" => %{"cost" => cost}}}}), do: cost
  defp graphql_reported_cost(_response), do: nil

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

  defp within_window?(observation, starts, now) do
    start = Map.get(starts, observation_resource(observation)) || rolling_start(now)
    DateTime.compare(observation.observed_at, start) != :lt
  end

  # Agent-shell rows written before the resource column existed, and any row
  # naming a resource Aiur does not meter, are counted against core: `gh` spends
  # the core budget on everything but `api graphql`.
  defp observation_resource(%{resource: resource}) when resource in @primary_resources, do: resource
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
  # An agent shell cannot see what a GraphQL query cost, so its rows carry one
  # point and are marked estimated rather than silently counted as exact.
  defp parse_shell_observation(line) do
    with [unix, consumer, direction | rest] <- line |> String.trim() |> String.split("\t"),
         {unix, ""} <- Integer.parse(unix),
         {:ok, observed_at} <- DateTime.from_unix(unix),
         true <- direction in ["read", "write"],
         true <- consumer == @unattributed or Regex.match?(~r/^ticket:\d+$/, consumer) do
      resource = shell_resource(rest)

      %{
        consumer: consumer,
        direction: String.to_existing_atom(direction),
        resource: resource,
        cost: 1,
        cost_source: if(resource == "graphql", do: :assumed, else: :reported),
        observed_at: observed_at
      }
    else
      _invalid -> nil
    end
  end

  defp shell_resource([resource | _rest]) when resource in @primary_resources, do: resource
  defp shell_resource(_columns), do: "core"

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
    ticket_number_from_url(request) || ticket_number_from_variables(request) || graphql_operation(request) || "unattributed"
  end

  defp graphql_operation(%{body: %{"query" => query}}) when is_binary(query) do
    case Regex.run(~r/^\s*(?:query|mutation)\s+([_A-Za-z][_0-9A-Za-z]*)/, query) do
      [_, operation] -> "github:#{operation}"
      _anonymous -> nil
    end
  end

  defp graphql_operation(_request), do: nil

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

  defp rate_limit_endpoint?(%{url: url}) when is_binary(url), do: URI.parse(url).path == "/rate_limit"
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
      {^resource, reset_at, threshold} = key, acc ->
        if DateTime.compare(reset_at, window.reset_at) == :eq and threshold_active?(window, threshold) do
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
