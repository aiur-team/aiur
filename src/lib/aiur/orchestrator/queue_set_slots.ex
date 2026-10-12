defmodule Aiur.Orchestrator.QueueSetSlots do
  @moduledoc "Serialized admission for active queue sets, spill reserves and unknown earlier readiness."

  alias Aiur.BuildQueue.Hints
  alias Aiur.Config
  alias Aiur.Orchestrator.{OptimisticSlots, Slots, State}

  @spec ordering() :: map()
  def ordering do
    snapshot = Hints.sets()

    if Config.settings!().build_queue.set_order == "ranked" and snapshot do
      ranks = Map.new(snapshot.sets, &{&1.id, &1.rank})
      for {id, member} <- snapshot.members, Map.has_key?(ranks, member.set_id), into: %{}, do: {id, {0, ranks[member.set_id], member.position}}
    else
      %{}
    end
  end

  @spec sort_key(String.t(), map()) :: tuple()
  def sort_key(id, ordering), do: Map.get(ordering, id, {1, 0, 0})

  @spec reason(String.t(), State.t()) :: String.t() | nil
  def reason(id, state) do
    snapshot = Hints.sets()
    member = snapshot && snapshot.members[id]
    if member, do: set_reason(member, snapshot, state, Config.settings!().build_queue)
  end

  @spec waiting(String.t(), State.t()) :: String.t()
  def waiting(id, state), do: reason(id, state) || "queue_set_order: waiting for queue set admission"

  @spec waiting_reason(atom(), String.t(), State.t()) :: String.t()
  def waiting_reason(:queue_set_order, id, state), do: waiting(id, state)
  def waiting_reason(:optimistic_share, _id, state), do: OptimisticSlots.waiting(state)

  defp set_reason(member, snapshot, state, settings) do
    sets = Enum.filter(snapshot.sets, &(&1.unfinished and not &1.held))
    current = Enum.find(sets, &(&1.id == member.set_id))
    if current, do: admission(current, sets, snapshot, state, settings)
  end

  defp admission(current, sets, snapshot, state, settings) do
    occupied = MapSet.union(state.claimed, MapSet.new(Map.keys(state.running)))
    active = Enum.filter(sets, &(&1.active or occupied?(&1.id, snapshot.members, occupied)))
    earlier = Enum.take_while(sets, &(&1.id != current.id))
    unknown = Enum.find(earlier, &unknown?(&1, snapshot.max_age_ms))
    earliest = List.first(earlier)

    cond do
      settings.set_order == "ranked" and (settings.max_active_sets != nil or settings.spill_reserve_slots > 0) and unknown ->
        message(current, unknown, "readiness unknown; may have ready work")

      active_limit?(settings.max_active_sets, active, current.id) ->
        message(current, List.first(active), "max_active_sets #{settings.max_active_sets}")

      reserve_limit?(settings.spill_reserve_slots, earliest, state) ->
        message(current, earliest, "spill reserve #{settings.spill_reserve_slots} slots")

      true ->
        nil
    end
  end

  defp active_limit?(nil, _active, _id), do: false
  defp active_limit?(limit, active, id), do: length(active) >= limit and not Enum.any?(active, &(&1.id == id))

  defp reserve_limit?(reserve, earliest, state), do: reserve > 0 and earliest != nil and Slots.available_slots(state) <= reserve

  defp occupied?(set_id, members, occupied), do: Enum.any?(occupied, &(members[&1] && members[&1].set_id == set_id))

  defp unknown?(set, max_age) do
    now = System.system_time(:millisecond)
    set.unknown or is_nil(set.observed_at_ms) or set.observed_at_ms > now or now - set.observed_at_ms > max_age
  end

  defp message(current, earlier, detail), do: "queue_set_order: set #{current.rank + 1} waits for set #{earlier.rank + 1} (#{detail})"
end
