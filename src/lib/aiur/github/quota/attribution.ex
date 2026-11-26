defmodule Aiur.GitHub.Quota.Attribution do
  @moduledoc false

  alias Aiur.GitHub.{GraphQLCost, RequestLog}
  alias Aiur.GitHub.Quota.Windows

  @primary_resources ~w(core graphql)
  # Anonymous reads bill the 60/hr unauthenticated IP allowance, not the
  # authenticated core budget. They get their own window so an exhausted
  # anonymous allowance stays visible without gating fleet dispatch, and so a
  # `limit: 60` response can never overwrite the authenticated `core` window.
  @anonymous_resource "core:anonymous"
  @metered_resources [@anonymous_resource | @primary_resources]
  @attribution_window_seconds 60 * 60
  # Both primary GitHub budgets run on a one-hour window, so the window that
  # a `reset_at` closes opened an hour before it.
  @quota_window_seconds 60 * 60
  @unattributed "unattributed"
  # The shortest window slice a per-hour rate may be extrapolated from. One
  # second of evidence multiplied by 3,600 is not a rate, it is an artefact.
  @min_rate_sample_seconds 60

  @spec attribute_request(map(), map(), term(), DateTime.t()) :: map()
  def attribute_request(state, request, result, now) do
    if Windows.rate_limit_endpoint?(request) do
      state
    else
      resource = Windows.request_resource(request)
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
  @spec log_request(map(), map(), term(), DateTime.t()) :: map()
  def log_request(state, request, result, now) do
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

  @spec prune_observations(map(), DateTime.t()) :: map()
  def prune_observations(state, now) do
    cutoff = DateTime.add(now, -@attribution_window_seconds, :second)
    %{state | observations: Enum.filter(state.observations, &(DateTime.compare(&1.observed_at, cutoff) != :lt))}
  end

  # The meter counts the live quota window, which opened an hour before its
  # reset — a rolling hour of attribution would summarize a different span than
  # the number printed beside it. Where no window has been observed for a
  # resource there is nothing to reconcile against, and the rolling hour is the
  # honest fallback.
  @spec observations_in_window(map(), DateTime.t()) :: [map()]
  def observations_in_window(state, now) do
    starts = Map.new(@primary_resources, &{&1, window_start(state.windows, &1, now)})
    Enum.filter(state.observations ++ state.shell_observations, &within_window?(&1, starts, now))
  end

  @spec window_start(map(), String.t(), DateTime.t()) :: DateTime.t()
  def window_start(windows, resource, now) do
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
  @spec observation_resource(map()) :: String.t()
  def observation_resource(%{resource: resource}) when resource in @metered_resources, do: resource
  def observation_resource(_observation), do: "core"

  @spec summarize_attribution([map()]) :: [map()]
  def summarize_attribution(observations) do
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
  @spec summarize_callers([map()], map(), DateTime.t()) :: [map()]
  def summarize_callers(observations, windows, now) do
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

  # Core and GraphQL are separate budgets billed in different units, so the
  # per-consumer figure keeps them apart as well as summed: an operator asking
  # "which budget is this ticket burning" needs the split.
  defp costs_by_resource(observations) do
    observations
    |> Enum.group_by(&observation_resource/1)
    |> Map.new(fn {resource, entries} -> {resource, total_cost(entries)} end)
  end

  @spec total_cost([map()]) :: non_neg_integer()
  def total_cost(observations), do: Enum.reduce(observations, 0, &(observation_cost(&1) + &2))

  defp observation_cost(%{cost: cost}) when is_integer(cost) and cost >= 0, do: cost
  defp observation_cost(_observation), do: 1

  @spec estimated?([map()]) :: boolean()
  def estimated?(observations), do: Enum.any?(observations, &(Map.get(&1, :cost_source) == :assumed))

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
end
