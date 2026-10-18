defmodule Aiur.AgentQueueStore.TargetIndex do
  @moduledoc false

  alias Aiur.AgentQueueItem
  alias Aiur.AgentQueueStore

  @spec add_item(AgentQueueStore.t(), AgentQueueItem.t()) :: AgentQueueStore.t()
  def add_item(%AgentQueueStore{} = store, %AgentQueueItem{id: id, target_issue_identifier: target} = item) do
    ids = Map.update(store.item_ids_by_target, target, [id], &[id | &1])
    event_ids = MapSet.union(store.queued_event_ids, event_ids(item))
    %{store | item_ids_by_target: ids, queued_event_ids: event_ids}
  end

  @spec items_for(AgentQueueStore.t(), String.t()) :: [AgentQueueItem.t()]
  def items_for(%AgentQueueStore{} = store, target) do
    store.item_ids_by_target
    |> Map.get(target, [])
    |> Enum.map(&Map.get(store.items, &1))
    |> Enum.reject(&is_nil/1)
  end

  @spec update_delivered_items(AgentQueueStore.t(), String.t(), (AgentQueueItem.t() -> AgentQueueItem.t())) ::
          {AgentQueueStore.t(), [AgentQueueItem.t()]}
  def update_delivered_items(%AgentQueueStore{} = store, target, updater) do
    store
    |> items_for(target)
    |> Enum.filter(&match?(%AgentQueueItem{status: :delivered}, &1))
    |> Enum.sort_by(& &1.sequence)
    |> Enum.reduce({store, []}, fn item, {acc, updated_items} ->
      updated = updater.(item)
      next = acc |> AgentQueueStore.put_item(updated) |> maybe_append_pending(updated)
      {next, [updated | updated_items]}
    end)
    |> then(fn {updated_store, updated_items} -> {updated_store, Enum.reverse(updated_items)} end)
  end

  defp maybe_append_pending(store, %AgentQueueItem{status: :pending, target_issue_identifier: target, id: id}) do
    AgentQueueStore.append_pending_id(store, target, id)
  end

  defp maybe_append_pending(store, _item), do: store

  defp event_ids(%AgentQueueItem{category: :coordination_event, event_type: :events_digest, body: %{events: events}}) do
    events
    |> List.wrap()
    |> Enum.map(&event_id/1)
    |> Enum.filter(&is_integer/1)
    |> MapSet.new()
  end

  defp event_ids(_item), do: MapSet.new()

  defp event_id(event) when is_map(event), do: Map.get(event, :id) || Map.get(event, "id")
  defp event_id(_event), do: nil
end
