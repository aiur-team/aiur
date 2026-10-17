defmodule Aiur.AgentQueueStore.TargetIndex do
  @moduledoc false

  alias Aiur.AgentQueueItem
  alias Aiur.AgentQueueStore

  @spec add_item(AgentQueueStore.t(), AgentQueueItem.t()) :: AgentQueueStore.t()
  def add_item(%AgentQueueStore{} = store, %AgentQueueItem{id: id, target_issue_identifier: target}) do
    ids = Map.update(store.item_ids_by_target, target, [id], &[id | &1])
    %{store | item_ids_by_target: ids}
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
      next = acc |> put_item(updated) |> maybe_append_pending(updated)
      {next, [updated | updated_items]}
    end)
    |> then(fn {updated_store, updated_items} -> {updated_store, Enum.reverse(updated_items)} end)
  end

  defp put_item(store, %AgentQueueItem{id: id} = item), do: %{store | items: Map.put(store.items, id, item)}

  defp maybe_append_pending(store, %AgentQueueItem{status: :pending, target_issue_identifier: target, id: id}) do
    pending = Map.get(store.pending_ids_by_target, target, [])
    updated = if id in pending, do: pending, else: pending ++ [id]
    %{store | pending_ids_by_target: Map.put(store.pending_ids_by_target, target, updated)}
  end

  defp maybe_append_pending(store, _item), do: store
end
