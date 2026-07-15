defmodule Aiur.ProviderAccountGeneration.Tombstones do
  @moduledoc false

  alias Aiur.ProviderAccountGeneration.{Continuity, Monitor, Snapshot}

  @spec retire(map(), tuple(), map()) :: map()
  def retire(state, key, snapshot) do
    {entry, entries} = Map.pop(state.entries, key)
    Monitor.clear(entry)
    :ok = Continuity.forget(state.continuity, key)

    tombstones = Map.put(state.tombstones, key, snapshot)
    order = [key | Enum.reject(state.tombstone_order, &(&1 == key))]
    {tombstones, order} = trim(tombstones, order, state.tombstone_limit)

    %{
      state
      | entries: entries,
        tombstones: tombstones,
        tombstone_order: order
    }
  end

  @spec retire_monitored(map(), reference()) :: {[{String.t(), map(), atom()}], map()}
  def retire_monitored(state, monitor) do
    Enum.reduce(state.entries, {[], state}, fn {key, entry}, {changes, state} ->
      case entry.monitor do
        {^monitor, _owner_pid} when is_binary(entry.snapshot.generation) ->
          {provider, backend, _binding} = key
          snapshot = Snapshot.unknown(provider, backend, entry.snapshot.source, :continuity_lost, state.clock.())
          {[{entry.topic, snapshot, :invalidated} | changes], retire(state, key, snapshot)}

        {^monitor, _owner_pid} ->
          {changes, retire(state, key, entry.snapshot)}

        _ ->
          {changes, state}
      end
    end)
  end

  defp trim(tombstones, order, limit) when length(order) <= limit, do: {tombstones, order}

  defp trim(tombstones, order, limit) do
    oldest = List.last(order)
    trim(Map.delete(tombstones, oldest), List.delete_at(order, -1), limit)
  end
end
