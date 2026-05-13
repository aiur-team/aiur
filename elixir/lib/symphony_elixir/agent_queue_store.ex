defmodule SymphonyElixir.AgentQueueStore do
  @moduledoc """
  In-memory queue state and transitions for agent-facing items.
  """

  alias SymphonyElixir.AgentQueueItem

  @type t :: %__MODULE__{
          next_id: integer(),
          next_sequence: integer(),
          items: %{optional(integer()) => AgentQueueItem.t()},
          pending_ids_by_target: %{optional(String.t()) => [integer()]}
        }

  defstruct next_id: 1, next_sequence: 1, items: %{}, pending_ids_by_target: %{}

  @type enqueue_attrs :: %{
          required(:target_issue_identifier) => String.t(),
          required(:source) => atom(),
          required(:category) => AgentQueueItem.category(),
          required(:event_type) => atom(),
          required(:body) => map(),
          optional(:delivery) => map(),
          optional(:dedupe_key) => String.t(),
          optional(:causal_refs) => [String.t()],
          optional(:subscription) => map()
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec enqueue(t(), enqueue_attrs()) :: {t(), AgentQueueItem.t()}
  def enqueue(%__MODULE__{} = store, attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    target_issue_identifier = Map.fetch!(attrs, :target_issue_identifier)
    delivery = normalize_delivery(Map.get(attrs, :delivery, %{}))

    item = %AgentQueueItem{
      id: store.next_id,
      sequence: store.next_sequence,
      target_issue_identifier: target_issue_identifier,
      source: Map.fetch!(attrs, :source),
      category: Map.fetch!(attrs, :category),
      event_type: Map.fetch!(attrs, :event_type),
      body: Map.fetch!(attrs, :body),
      delivery: delivery,
      dedupe_key: Map.get(attrs, :dedupe_key),
      causal_refs: Map.get(attrs, :causal_refs, []),
      subscription: Map.get(attrs, :subscription),
      status: :pending,
      inserted_at: now
    }

    store =
      store
      |> maybe_supersede_deduped(item, now)
      |> put_item(item)
      |> append_pending_id(target_issue_identifier, item.id)
      |> bump_counters()

    {store, item}
  end

  @spec claim_next_deliverable(t(), String.t()) :: {t(), AgentQueueItem.t() | nil}
  def claim_next_deliverable(%__MODULE__{} = store, target_issue_identifier)
      when is_binary(target_issue_identifier) do
    pending_ids = Map.get(store.pending_ids_by_target, target_issue_identifier, [])

    case next_pending_item(store, pending_ids) do
      nil ->
        {store, nil}

      %AgentQueueItem{} = item ->
        claimed_item = %{item | status: :delivered, delivered_at: DateTime.utc_now()}

        store =
          store
          |> put_item(claimed_item)
          |> remove_pending_id(target_issue_identifier, claimed_item.id)

        {store, claimed_item}
    end
  end

  @spec mark_consumed(t(), integer()) :: {t(), AgentQueueItem.t() | nil}
  def mark_consumed(%__MODULE__{} = store, item_id) when is_integer(item_id) do
    update_item(store, item_id, fn item ->
      %{item | status: :consumed, consumed_at: DateTime.utc_now(), failure_reason: nil}
    end)
  end

  @spec mark_failed(t(), integer(), term()) :: {t(), AgentQueueItem.t() | nil}
  def mark_failed(%__MODULE__{} = store, item_id, reason) when is_integer(item_id) do
    update_item(store, item_id, fn item ->
      %{item | status: :failed, failed_at: DateTime.utc_now(), failure_reason: reason}
    end)
  end

  @spec mark_superseded(t(), integer()) :: {t(), AgentQueueItem.t() | nil}
  def mark_superseded(%__MODULE__{} = store, item_id) when is_integer(item_id) do
    case Map.get(store.items, item_id) do
      %AgentQueueItem{target_issue_identifier: target, status: :pending} = item ->
        updated = %{item | status: :superseded, superseded_at: DateTime.utc_now()}

        store =
          store
          |> put_item(updated)
          |> remove_pending_id(target, item_id)

        {store, updated}

      %AgentQueueItem{} ->
        update_item(store, item_id, fn item ->
          %{item | status: :superseded, superseded_at: DateTime.utc_now()}
        end)

      nil ->
        {store, nil}
    end
  end

  @spec get(t(), integer()) :: AgentQueueItem.t() | nil
  def get(%__MODULE__{} = store, item_id) when is_integer(item_id), do: Map.get(store.items, item_id)

  @spec list_pending(t(), String.t()) :: [AgentQueueItem.t()]
  def list_pending(%__MODULE__{} = store, target_issue_identifier) when is_binary(target_issue_identifier) do
    target_issue_identifier
    |> then(&Map.get(store.pending_ids_by_target, &1, []))
    |> Enum.map(&Map.get(store.items, &1))
    |> Enum.reject(&is_nil/1)
    |> sort_items()
  end

  defp maybe_supersede_deduped(store, %AgentQueueItem{dedupe_key: nil}, _now), do: store

  defp maybe_supersede_deduped(
         %__MODULE__{} = store,
         %AgentQueueItem{target_issue_identifier: target, dedupe_key: dedupe_key},
         now
       ) do
    pending_ids = Map.get(store.pending_ids_by_target, target, [])

    Enum.reduce(pending_ids, store, fn pending_id, acc ->
      case Map.get(acc.items, pending_id) do
        %AgentQueueItem{dedupe_key: ^dedupe_key, status: :pending} = existing ->
          updated = %{existing | status: :superseded, superseded_at: now}

          acc
          |> put_item(updated)
          |> remove_pending_id(target, pending_id)

        _ ->
          acc
      end
    end)
  end

  defp next_pending_item(store, pending_ids) do
    pending_ids
    |> Enum.map(&Map.get(store.items, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(&1.status == :pending))
    |> sort_items()
    |> List.first()
  end

  defp sort_items(items) do
    Enum.sort_by(items, fn item -> {priority_rank(item.delivery[:priority]), item.sequence} end)
  end

  defp priority_rank(:now), do: 0
  defp priority_rank(:next), do: 1
  defp priority_rank(:later), do: 2
  defp priority_rank(_other), do: 9

  defp normalize_delivery(delivery) when is_map(delivery) do
    %{
      priority: Map.get(delivery, :priority, :next),
      durability: Map.get(delivery, :durability, :durable),
      consume_at: Map.get(delivery, :consume_at, :safe_checkpoint),
      interrupt_requested: Map.get(delivery, :interrupt_requested, false),
      fallback: Map.get(delivery, :fallback)
    }
  end

  defp put_item(%__MODULE__{} = store, %AgentQueueItem{id: id} = item) do
    %{store | items: Map.put(store.items, id, item)}
  end

  defp append_pending_id(%__MODULE__{} = store, target_issue_identifier, item_id) do
    pending_ids = Map.get(store.pending_ids_by_target, target_issue_identifier, [])
    pending_ids_by_target = Map.put(store.pending_ids_by_target, target_issue_identifier, pending_ids ++ [item_id])
    %{store | pending_ids_by_target: pending_ids_by_target}
  end

  defp remove_pending_id(%__MODULE__{} = store, target_issue_identifier, item_id) do
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

  defp bump_counters(%__MODULE__{} = store) do
    %{store | next_id: store.next_id + 1, next_sequence: store.next_sequence + 1}
  end

  defp update_item(%__MODULE__{} = store, item_id, updater) do
    case Map.get(store.items, item_id) do
      %AgentQueueItem{} = item ->
        updated = updater.(item)
        {put_item(store, updated), updated}

      nil ->
        {store, nil}
    end
  end
end
