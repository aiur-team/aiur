defmodule Aiur.Orchestrator.StatusObservation do
  @moduledoc "Observation ages for the shared fleet read model and its renderers."

  alias Aiur.Boot

  @groups [:fleet, :capacity, :per_ticket, :retries, :dispatch]
  @rows [:running, :retrying, :idle, :statuses]

  @spec attach(map(), map(), DateTime.t()) :: map()
  def attach(snapshot, state, now) do
    captured = Map.get(state, :status_observed_at) || now
    tracker = newest_observation(Map.values(state.tracker_observations))
    {oldest_ticket_id, oldest_tracker} = oldest_ticket_observation(state.tracker_observations)
    observations = Map.new(@groups, &{&1, observation(captured, now)})

    per_ticket =
      observation(tracker, now)
      |> Map.put(:oldest_ticket_id, oldest_ticket_id)
      |> Map.put(:oldest_observed_at, iso8601(oldest_tracker))
      |> Map.put(:oldest_age_ms, observation(oldest_tracker, now).age_ms)

    observations = Map.put(observations, :per_ticket, per_ticket)
    observations = Map.put(observations, :dispatch, observation(state.dispatch_capacity_sample[:observed_at], now))

    snapshot
    |> Map.put(:ticket_observations, state.tracker_observations)
    |> Map.put(:observations, observations)
    |> Map.put(:daemon_started_at, DateTime.to_iso8601(Boot.started_at()))
    |> Map.update!(:capacity, &(Map.merge(&1, observations.capacity) |> Map.put(:dispatch_observation, observations.dispatch)))
    |> refresh(now)
  end

  @spec refresh(map(), DateTime.t()) :: map()
  def refresh(snapshot, now \\ DateTime.utc_now()) do
    case snapshot[:observations] do
      %{} = groups ->
        groups =
          Map.new(groups, fn {key, value} -> {key, refresh_group(key, value, now)} end)

        snapshot = Map.put(snapshot, :observations, groups)
        snapshot = Map.update(snapshot, :capacity, nil, &refresh_capacity(&1, now))
        Enum.reduce(@rows, snapshot, &refresh_rows(&1, &2, groups, now))

      _missing ->
        snapshot
    end
  end

  defp refresh_capacity(%{} = capacity, now) do
    capacity
    |> Map.merge(observation(capacity[:observed_at], now))
    |> Map.update(:dispatch_observation, observation(nil, now), &observation(&1[:observed_at], now))
  end

  defp refresh_capacity(capacity, _now), do: capacity

  defp refresh_group(:per_ticket, value, now) do
    observation(value[:observed_at], now)
    |> Map.merge(%{
      oldest_ticket_id: value[:oldest_ticket_id],
      oldest_observed_at: value[:oldest_observed_at],
      oldest_age_ms: observation(value[:oldest_observed_at], now).age_ms
    })
  end

  defp refresh_group(_group, value, now), do: observation(value[:observed_at], now)

  defp refresh_rows(key, snapshot, groups, now) do
    case snapshot[key] do
      rows when is_list(rows) ->
        Map.put(snapshot, key, Enum.map(rows, &row_observation(&1, key, snapshot, groups, now)))

      _missing ->
        snapshot
    end
  end

  defp row_observation(row, key, snapshot, groups, now) do
    idle? = key == :idle or (key == :statuses and Enum.any?(snapshot[:idle] || [], &(&1.issue_id == row.issue_id)))
    source = if idle?, do: observation(snapshot.ticket_observations[row.issue_id], now), else: groups.fleet
    source = if row[:work_state] == :retrying, do: observation(row[:last_failure_at], now), else: source
    row = Map.merge(row, source)
    if row[:work_state] == :retrying, do: Map.put(row, :retry_scope, "since daemon start #{snapshot.daemon_started_at}"), else: row
  end

  @spec observation(DateTime.t() | String.t() | nil, DateTime.t()) :: map()
  def observation(%DateTime{} = observed, now),
    do: %{observed_at: DateTime.to_iso8601(observed), age_ms: max(DateTime.diff(now, observed, :millisecond), 0)}

  def observation(observed, now) when is_binary(observed) do
    case DateTime.from_iso8601(observed) do
      {:ok, datetime, _offset} -> observation(datetime, now)
      _invalid -> observation(nil, now)
    end
  end

  def observation(_unknown, _now), do: %{observed_at: nil, age_ms: nil}

  @spec observe_tickets(map(), [map()], map()) :: map()
  def observe_tickets(state, issues, retained) do
    now = DateTime.utc_now()
    observed = Map.new(issues, &{&1.id, now})
    observations = Map.merge(state.tracker_observations, observed) |> Map.take(Map.keys(retained))
    %{state | tracker_observations: observations}
  end

  @spec sample_observed_at(map()) :: DateTime.t() | nil
  def sample_observed_at(%{sampled_at_ms: ms}) when is_integer(ms) do
    now = DateTime.utc_now()
    DateTime.add(now, -max(System.monotonic_time(:millisecond) - ms, 0), :millisecond)
  end

  def sample_observed_at(_unavailable), do: nil

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(_unknown), do: nil

  defp newest_observation([]), do: nil
  defp newest_observation(times), do: Enum.max_by(times, &DateTime.to_unix(&1, :microsecond))

  defp oldest_ticket_observation(observations) do
    Enum.min_by(observations, fn {_id, observed_at} -> DateTime.to_unix(observed_at, :microsecond) end, fn -> {nil, nil} end)
  end

  @spec label(map() | nil) :: String.t()
  defdelegate label(observation), to: Aiur.Protocol.ObservationAge
  @spec row_label(map()) :: String.t()
  defdelegate row_label(row), to: Aiur.Protocol.ObservationAge

  defp oldest_suffix(:per_ticket, %{per_ticket: %{oldest_ticket_id: id, oldest_age_ms: age}}) when not is_nil(id),
    do: "; oldest retained ##{id} #{label(%{age_ms: age})}"

  defp oldest_suffix(:per_ticket, _groups), do: ""
  defp oldest_suffix(_group, _groups), do: ""

  @spec print_groups(map()) :: :ok
  def print_groups(%{observations: groups}) when is_map(groups) do
    Enum.each(@groups, fn group ->
      suffix = oldest_suffix(group, groups)
      IO.puts("#{group |> Atom.to_string() |> String.upcase()} OBSERVATION #{label(groups[group])}#{suffix}")
    end)
  end

  def print_groups(_snapshot), do: :ok
end
