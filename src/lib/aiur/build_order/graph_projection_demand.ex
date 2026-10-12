defmodule Aiur.BuildOrder.GraphProjection.Demand do
  @moduledoc false

  # Selected-root retention, eviction, demand registration and demander monitors.
  # Runs inside the projection process: every `self()` here is the GenServer.

  alias Aiur.BuildOrder.GraphProjection.{Failure, Policy, Reads, Resources, Schedule, Snapshot}
  alias Aiur.BuildOrder.ProviderHealth

  @spec ensure_selected_entry(map(), Aiur.TrackerIdentity.t()) :: {:ok, map(), [tuple()]} | {:error, Failure.t()}
  def ensure_selected_entry(state, identity) do
    key = Policy.root_key(identity)

    case Map.fetch(state.selected, key) do
      {:ok, entry} ->
        entry = %{entry | last_access_ms: Schedule.now_ms(state)}
        {:ok, %{state | selected: Map.put(state.selected, key, entry)}, []}

      :error ->
        with {:ok, state, events} <- make_selected_room(state) do
          entry = Policy.unavailable_entry({:selected, identity}, Schedule.now_ms(state))
          {:ok, %{state | selected: Map.put(state.selected, key, entry)}, events}
        end
    end
  end

  defp make_selected_room(state) when map_size(state.selected) < state.policy.max_selected_roots,
    do: {:ok, state, []}

  defp make_selected_room(state) do
    case eviction_candidate(state) do
      {key, entry} ->
        state = evict_selected(state, key, entry)
        {:ok, state, [{:health, evicted_snapshot(entry, state)}]}

      nil ->
        {:error, %Failure{kind: :capacity}}
    end
  end

  defp eviction_candidate(state) do
    state.selected
    |> Enum.reject(fn {_key, entry} -> entry.inflight || MapSet.size(entry.demanders) > 0 end)
    |> Enum.min_by(fn {_key, entry} -> entry.last_access_ms end, fn -> nil end)
  end

  defp evict_selected(state, key, entry) do
    Schedule.cancel_entry_timer(entry)

    %{
      state
      | selected: Map.delete(state.selected, key),
        # The marker describes a graph this process no longer holds. Keeping it
        # would tell a later re-selection of the same root that it was already
        # current when it holds nothing at all.
        selected_fingerprints: Map.delete(state.selected_fingerprints, key),
        member_due: Resources.drop_member_due(state.member_due, key),
        pending: MapSet.delete(state.pending, entry.scope),
        forced: MapSet.delete(state.forced, entry.scope)
    }
  end

  defp evicted_snapshot(entry, state) do
    health = ProviderHealth.new(entry.generation, :unavailable, false, failure: :evicted)

    %Snapshot{
      scope: entry.scope,
      repository: state.active_repository,
      authority_epoch: state.authority_epoch,
      generation: entry.generation,
      health: health
    }
  end

  @spec enforce_retention_bound(map()) :: map()
  def enforce_retention_bound(state) do
    if map_size(state.selected) <= state.policy.max_selected_roots do
      state
    else
      case eviction_candidate(state) do
        {key, entry} -> state |> evict_selected(key, entry) |> enforce_retention_bound()
        nil -> state
      end
    end
  end

  # The one thing arriving demand does spend on, and deliberately not a cadence.
  # A held graph the catalog has *already* said is superseded was requested once
  # and declined, because `request_scope/2` refuses a root nobody is watching
  # and nothing re-raises the request when a watcher returns. That is how a page
  # comes to render six-hour-old percentages beside a live catalog (#2608).
  #
  # The gate is the catalog's own marker, not elapsed time: a page opened on an
  # unmoved root buys nothing, holding it open buys nothing, and one catalog
  # move buys exactly one read. A cold root is deliberately excluded — demand
  # still never buys the *first* read, which is `refresh/2`'s job.
  @spec request_superseded_demand(map(), Aiur.TrackerIdentity.t()) :: {map(), [tuple()]}
  def request_superseded_demand(state, identity) do
    case Map.get(state.selected, Policy.root_key(identity)) do
      %{data: data} = entry when not is_nil(data) ->
        if Reads.selected_fingerprint_moved?(state, entry) and Schedule.retry_due?(entry, state),
          do: Reads.request_scope(state, entry.scope),
          else: {state, []}

      _entry ->
        {state, []}
    end
  end

  @spec add_demand(map(), Aiur.TrackerIdentity.t(), pid()) :: {map(), Aiur.TrackerIdentity.t()}
  def add_demand(state, identity, pid) do
    key = Policy.root_key(identity)
    demand_key = {key, pid}

    if Map.has_key?(state.monitor_by_demand, demand_key) do
      {state, identity}
    else
      ref = Process.monitor(pid)
      entry = Map.fetch!(state.selected, key)
      entry = %{entry | demanders: MapSet.put(entry.demanders, pid), last_access_ms: Schedule.now_ms(state)}

      state = %{
        state
        | selected: Map.put(state.selected, key, entry),
          monitor_by_ref: Map.put(state.monitor_by_ref, ref, demand_key),
          monitor_by_demand: Map.put(state.monitor_by_demand, demand_key, ref)
      }

      {state, identity}
    end
  end

  @spec remove_demand(map(), Aiur.TrackerIdentity.t(), pid()) :: map()
  def remove_demand(state, identity, pid) do
    key = Policy.root_key(identity)
    remove_demand_key(state, {key, pid}, true)
  end

  @spec remove_demand_by_monitor(map(), reference(), pid()) :: map()
  def remove_demand_by_monitor(state, ref, _pid) do
    case Map.get(state.monitor_by_ref, ref) do
      nil -> state
      demand_key -> remove_demand_key(state, demand_key, false)
    end
  end

  defp remove_demand_key(state, {key, pid} = demand_key, demonitor?) do
    case Map.pop(state.monitor_by_demand, demand_key) do
      {nil, _monitor_by_demand} ->
        state

      {ref, monitor_by_demand} ->
        if demonitor?, do: Process.demonitor(ref, [:flush])

        selected =
          Map.update(state.selected, key, nil, &remove_demander(&1, pid))
          |> Map.reject(fn {_key, entry} -> is_nil(entry) end)

        scope = selected_scope(state, key)
        held? = active_scope_in?(selected, key)
        pending = if(held?, do: state.pending, else: MapSet.delete(state.pending, scope))
        # A forced request outlives neither its root nor its watchers: with the
        # last demander gone there is nobody the read would be bought for.
        forced = if(held?, do: state.forced, else: MapSet.delete(state.forced, scope))

        %{
          state
          | selected: selected,
            pending: pending,
            forced: forced,
            monitor_by_ref: Map.delete(state.monitor_by_ref, ref),
            monitor_by_demand: monitor_by_demand
        }
    end
  end

  defp remove_demander(entry, pid) do
    entry = %{entry | demanders: MapSet.delete(entry.demanders, pid)}
    if MapSet.size(entry.demanders) == 0, do: Schedule.cancel_entry_schedule(entry), else: entry
  end

  defp selected_scope(state, key) do
    case Map.get(state.selected, key) do
      %{scope: scope} -> scope
      _entry -> {:selected, nil}
    end
  end

  defp active_scope_in?(selected, key) do
    case Map.get(selected, key) do
      %{demanders: demanders} -> MapSet.size(demanders) > 0
      _entry -> false
    end
  end

  @spec clear_demand_monitors(map()) :: map()
  def clear_demand_monitors(state) do
    Enum.each(Map.keys(state.monitor_by_ref), &Process.demonitor(&1, [:flush]))
    %{state | monitor_by_ref: %{}, monitor_by_demand: %{}}
  end
end
