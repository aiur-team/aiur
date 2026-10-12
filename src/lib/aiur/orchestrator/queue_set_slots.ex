defmodule Aiur.Orchestrator.QueueSetSlots do
  @moduledoc "Serialized admission for active queue sets, spill reserves and unknown earlier readiness."

  alias Aiur.Config
  alias Aiur.BuildQueue.Hints
  alias Aiur.Orchestrator.{Slots, State}

  @spec sort_key(String.t()) :: tuple()
  def sort_key(id) do
    snapshot = Hints.sets()

    if Config.settings!().build_queue.set_order == "ranked" and snapshot do
      case snapshot.members[id] do
        nil -> {1, 0, 0}
        member -> {0, Enum.find(snapshot.sets, &(&1.id == member.set_id)).rank, member.position}
      end
    else
      {0, 0, 0}
    end
  end

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
  def waiting_reason(:optimistic_share, _id, state), do: Aiur.Orchestrator.OptimisticSlots.waiting(state)

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
      settings.set_order == "ranked" and unknown ->
        message(current, unknown, "readiness unknown; may have ready work")

      settings.max_active_sets != nil and length(active) >= settings.max_active_sets and not Enum.any?(active, &(&1.id == current.id)) ->
        message(current, List.first(active), "max_active_sets #{settings.max_active_sets}")

      settings.spill_reserve_slots > 0 and earliest != nil and Slots.available_slots(state) <= settings.spill_reserve_slots ->
        message(current, earliest, "spill reserve #{settings.spill_reserve_slots} slots")

      true ->
        nil
    end
  end

  defp occupied?(set_id, members, occupied), do: Enum.any?(occupied, &(members[&1] && members[&1].set_id == set_id))

  defp unknown?(set, max_age) do
    now = System.system_time(:millisecond)
    set.unknown or is_nil(set.observed_at_ms) or set.observed_at_ms > now or now - set.observed_at_ms > max_age
  end

  defp message(current, earlier, detail), do: "queue_set_order: set #{current.rank + 1} waits for set #{earlier.rank + 1} (#{detail})"
end
