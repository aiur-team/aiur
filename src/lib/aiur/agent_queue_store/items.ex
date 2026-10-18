defmodule Aiur.AgentQueueStore.Items do
  @moduledoc false
  alias Aiur.AgentQueueItem
  alias Aiur.AgentQueueStore

  @doc false
  @spec put_item(term(), term()) :: term()
  def put_item(%AgentQueueStore{} = store, %AgentQueueItem{id: id} = item) do
    %{store | items: Map.put(store.items, id, item)}
  end

  @doc false
  @spec append_pending_id(term(), term(), term()) :: term()
  def append_pending_id(%AgentQueueStore{} = store, target_issue_identifier, item_id) do
    pending_ids = Map.get(store.pending_ids_by_target, target_issue_identifier, [])

    updated_pending_ids =
      if item_id in pending_ids do
        pending_ids
      else
        pending_ids ++ [item_id]
      end

    pending_ids_by_target = Map.put(store.pending_ids_by_target, target_issue_identifier, updated_pending_ids)
    %{store | pending_ids_by_target: pending_ids_by_target}
  end

  @doc false
  @spec remove_pending_id(term(), term(), term()) :: term()
  def remove_pending_id(%AgentQueueStore{} = store, target_issue_identifier, item_id) do
    pending_ids =
      store.pending_ids_by_target
      |> Map.get(target_issue_identifier, [])
      |> Enum.reject(&(&1 == item_id))

    pending_ids_by_target =
      if pending_ids == [] do
        Map.delete(store.pending_ids_by_target, target_issue_identifier)
      else
        Map.put(store.pending_ids_by_target, target_issue_identifier, pending_ids)
      end

    %{store | pending_ids_by_target: pending_ids_by_target}
  end

  @doc false
  @spec bump_counters(term()) :: term()
  def bump_counters(%AgentQueueStore{} = store) do
    %{store | next_id: store.next_id + 1, next_sequence: store.next_sequence + 1}
  end

  @doc false
  @spec update_item(term(), term(), term()) :: term()
  def update_item(%AgentQueueStore{} = store, item_id, updater) do
    case Map.get(store.items, item_id) do
      %AgentQueueItem{} = item ->
        updated = updater.(item)
        {put_item(store, updated), updated}

      nil ->
        {store, nil}
    end
  end

  @doc false
  @spec update_delivered_items(term(), term(), term()) :: term()
  def update_delivered_items(%AgentQueueStore{} = store, target_issue_identifier, updater) do
    store.items
    |> Map.values()
    |> Enum.filter(&match?(%AgentQueueItem{target_issue_identifier: ^target_issue_identifier, status: :delivered}, &1))
    |> Enum.sort_by(& &1.sequence)
    |> Enum.reduce({store, []}, fn item, {store_acc, updated_items} ->
      updated = updater.(item)

      next_store =
        store_acc
        |> put_item(updated)
        |> maybe_append_pending_after_restore(updated)

      {next_store, [updated | updated_items]}
    end)
    |> then(fn {updated_store, updated_items} -> {updated_store, Enum.reverse(updated_items)} end)
  end

  defp maybe_append_pending_after_restore(store, %AgentQueueItem{status: :pending, target_issue_identifier: target, id: id}) do
    append_pending_id(store, target, id)
  end

  defp maybe_append_pending_after_restore(store, _item), do: store
end
