defmodule Aiur.Orchestrator.StatusObservation do
  @moduledoc "Observation ages for the shared fleet read model and its renderers."

  alias Aiur.Boot

  @groups [:fleet, :capacity, :per_ticket, :retries, :dispatch]
  @rows [:running, :retrying, :idle, :statuses]

  @spec attach(map(), map(), DateTime.t()) :: map()
  def attach(snapshot, state, now) do
    captured = Map.get(state, :status_observed_at) || now
    tracker = oldest_observation(Map.values(state.tracker_observations))
    observations = Map.new(@groups, &{&1, observation(captured, now)})
    observations = Map.put(observations, :per_ticket, observation(tracker, now))
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
        groups = Map.new(groups, fn {key, value} -> {key, observation(value[:observed_at], now)} end)
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

  defp oldest_observation([]), do: nil
  defp oldest_observation(times), do: Enum.min_by(times, &DateTime.to_unix(&1, :microsecond))

  @spec label(map() | nil) :: String.t()
  defdelegate label(observation), to: Aiur.Protocol.ObservationAge
  @spec row_label(map()) :: String.t()
  defdelegate row_label(row), to: Aiur.Protocol.ObservationAge

  @spec print_groups(map()) :: :ok
  def print_groups(%{observations: groups}) when is_map(groups) do
    Enum.each(@groups, &IO.puts("#{&1 |> Atom.to_string() |> String.upcase()} OBSERVATION #{label(groups[&1])}"))
  end

  def print_groups(_snapshot), do: :ok
end
