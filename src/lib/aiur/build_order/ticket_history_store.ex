defmodule Aiur.BuildOrder.TicketHistoryStore do
  @moduledoc """
  Pure retention, generation, eviction, snapshot and health helpers for
  `Aiur.BuildOrder.TicketHistoryProvider`. It performs no I/O and no broadcasts;
  the provider owns both.
  """

  alias Aiur.BuildOrder.TicketHistory.Snapshot
  alias Aiur.TrackerIdentity

  @doc """
  Retains `entry`, evicting the least-recently-used identity at capacity.

  Returns the evicted entries with their generations so the caller can
  broadcast them after the state is updated.
  """
  @spec put(map(), map()) :: {:unchanged, map(), map()} | {:changed, map(), map(), [{map(), pos_integer()}]}
  def put(entry, state) do
    previous = Map.get(state.entries, key(entry.identity))
    {entry, state} = touch(entry, state)

    if same_content?(previous, entry) do
      {:unchanged, entry, put_unchanged(entry, state)}
    else
      {state, evicted} = make_room(state, entry.identity)
      {evicted, state} = allocate_eviction_generations(evicted, state)
      {generation, state} = allocate_generation(state)
      entry = %{entry | generation: generation}
      {:changed, entry, %{state | entries: Map.put(state.entries, key(entry.identity), entry)}, evicted}
    end
  end

  defp allocate_eviction_generations(entries, state) do
    Enum.map_reduce(entries, state, fn entry, state ->
      {generation, state} = allocate_generation(state)
      {{entry, generation}, state}
    end)
  end

  defp allocate_generation(state) do
    {state.next_generation, %{state | next_generation: state.next_generation + 1}}
  end

  defp same_content?(nil, _entry), do: false

  defp same_content?(previous, entry) do
    Map.drop(previous, [:last_access]) == Map.drop(entry, [:last_access])
  end

  @spec touch(map(), map()) :: {map(), map()}
  def touch(entry, state) do
    sequence = state.access_sequence + 1
    {%{entry | last_access: sequence}, %{state | access_sequence: sequence}}
  end

  @spec put_unchanged(map(), map()) :: map()
  def put_unchanged(entry, state) do
    %{state | entries: Map.put(state.entries, key(entry.identity), entry)}
  end

  defp make_room(state, identity) do
    identity_key = key(identity)

    if Map.has_key?(state.entries, identity_key) or map_size(state.entries) < state.max_identities do
      {state, []}
    else
      {evicted_key, evicted} =
        Enum.min_by(state.entries, fn {entry_key, entry} -> {entry.last_access, entry_key} end)

      {%{state | entries: Map.delete(state.entries, evicted_key)}, [evicted]}
    end
  end

  @spec snapshot(map(), map(), DateTime.t()) :: Snapshot.t()
  def snapshot(entry, state, now) do
    observed_at = latest_observation(entry)
    activity_health = activity_source_health(entry, now, state.stale_after_ms)
    freshness = freshness(observed_at, now, state.stale_after_ms)
    health = overall_health(entry, activity_health, freshness)

    %Snapshot{
      identity: entry.identity,
      generation: entry.generation,
      health: health,
      status_label: status_label(health),
      progress: progress(entry.activity),
      latest_evidence: latest_evidence(entry.activity),
      entries: entry.entries,
      truncated?: entry.truncated?,
      observed_at: observed_at,
      freshness: freshness,
      source_health: %{activity: activity_health, history: entry.history_health}
    }
  end

  @spec missing_snapshot(TrackerIdentity.t()) :: Snapshot.t()
  def missing_snapshot(identity) do
    %Snapshot{
      identity: identity,
      generation: :unknown,
      health: :missing_source,
      status_label: status_label(:missing_source),
      progress: %{status: :unknown},
      latest_evidence: %{status: :unknown},
      entries: [],
      truncated?: false,
      observed_at: nil,
      freshness: :unknown,
      source_health: %{activity: :missing_source, history: :missing_source}
    }
  end

  defp overall_health(%{history_health: :unavailable}, _activity_health, _freshness), do: :unavailable
  defp overall_health(_entry, :unavailable, _freshness), do: :unavailable
  defp overall_health(%{history_health: :missing_source}, _activity_health, _freshness), do: :missing_source
  defp overall_health(%{entries: [_ | _]}, :missing_source, _freshness), do: :restart_unknown
  defp overall_health(_entry, :missing_source, _freshness), do: :missing_source
  defp overall_health(_entry, :stale, _freshness), do: :stale
  defp overall_health(_entry, _activity_health, :stale), do: :stale
  defp overall_health(%{entries: []}, _activity_health, _freshness), do: :known_empty
  defp overall_health(_entry, _activity_health, _freshness), do: :available

  defp activity_source_health(%{activity_health: :available, activity: activity}, now, stale_after_ms) do
    if field(activity, :status) == :stale or freshness(field(activity, :observed_at), now, stale_after_ms) == :stale,
      do: :stale,
      else: :available
  end

  defp activity_source_health(%{activity_health: health}, _now, _stale_after_ms), do: health

  defp freshness(nil, _now, _stale_after_ms), do: :unknown

  defp freshness(%DateTime{} = observed_at, %DateTime{} = now, stale_after_ms) do
    if DateTime.diff(now, observed_at, :millisecond) > stale_after_ms, do: :stale, else: :fresh
  end

  defp latest_observation(entry) do
    activity_time = entry.activity && field(entry.activity, :observed_at)
    entry_time = entry.entries |> List.first() |> then(&(&1 && &1.observed_at))

    case {activity_time, entry_time} do
      {%DateTime{} = left, %DateTime{} = right} -> if(DateTime.compare(left, right) == :lt, do: right, else: left)
      {%DateTime{} = value, _} -> value
      {_, %DateTime{} = value} -> value
      _ -> nil
    end
  end

  defp progress(%{progress: progress}) when is_map(progress), do: progress
  defp progress(_activity), do: %{status: :unknown}
  defp latest_evidence(%{latest_evidence: evidence}) when is_map(evidence), do: evidence
  defp latest_evidence(_activity), do: %{status: :unknown}

  defp status_label(:available), do: "Recent ticket history available"
  defp status_label(:known_empty), do: "No recent structured ticket activity"
  defp status_label(:missing_source), do: "Structured ticket history source missing"
  defp status_label(:restart_unknown), do: "History restored; current activity unknown after restart"
  defp status_label(:stale), do: "Recent ticket history is stale"
  defp status_label(:unavailable), do: "Recent ticket history unavailable"

  @spec key(TrackerIdentity.t()) :: term()
  def key(identity), do: TrackerIdentity.github_key(identity)
  @spec field(term(), atom()) :: term()
  def field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  def field(_map, _key), do: nil
end
