defmodule Aiur.AgentQueueStore do
  @moduledoc """
  In-memory queue state and transitions for agent-facing items.
  """

  alias Aiur.AgentQueueItem
  alias Aiur.AgentQueueStore.Correlation
  alias Aiur.AgentQueueStore.Items

  @type t :: %__MODULE__{
          next_id: integer(),
          next_sequence: integer(),
          items: %{optional(integer()) => AgentQueueItem.t()},
          pending_ids_by_target: %{optional(String.t()) => [integer()]},
          item_id_by_action: %{optional(String.t()) => integer()},
          item_id_by_message_id: %{optional(String.t()) => integer()}
        }

  defstruct next_id: 1,
            next_sequence: 1,
            items: %{},
            pending_ids_by_target: %{},
            item_id_by_action: %{},
            item_id_by_message_id: %{}

  @type enqueue_attrs :: %{
          required(:target_issue_identifier) => String.t(),
          required(:source) => atom(),
          required(:category) => AgentQueueItem.category(),
          required(:event_type) => atom(),
          required(:body) => map(),
          optional(:delivery) => map(),
          optional(:action_id) => String.t(),
          optional(:correlation) => map(),
          optional(:message_id) => String.t(),
          optional(:dedupe_key) => String.t(),
          optional(:causal_refs) => [String.t()],
          optional(:turn_id) => String.t(),
          optional(:subscription) => map()
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec enqueue(t(), enqueue_attrs()) :: {t(), AgentQueueItem.t()}
  def enqueue(%__MODULE__{} = store, attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    target_issue_identifier = Map.fetch!(attrs, :target_issue_identifier)
    delivery = Correlation.normalize_delivery(Map.get(attrs, :delivery, %{}))

    item = %AgentQueueItem{
      id: store.next_id,
      sequence: store.next_sequence,
      target_issue_identifier: target_issue_identifier,
      source: Map.fetch!(attrs, :source),
      category: Map.fetch!(attrs, :category),
      event_type: Map.fetch!(attrs, :event_type),
      body: Map.fetch!(attrs, :body),
      delivery: delivery,
      action_id: Map.get(attrs, :action_id),
      correlation: Map.get(attrs, :correlation),
      message_id: Map.get(attrs, :message_id),
      dedupe_key: Map.get(attrs, :dedupe_key),
      causal_refs: Map.get(attrs, :causal_refs, []),
      turn_id: Map.get(attrs, :turn_id),
      subscription: Map.get(attrs, :subscription),
      status: :pending,
      delivery_attempts: 0,
      inserted_at: now
    }

    store =
      store
      |> maybe_supersede_deduped(item, now)
      |> Items.put_item(item)
      |> Items.append_pending_id(target_issue_identifier, item.id)
      |> Items.bump_counters()

    {store, item}
  end

  @doc """
  Enqueue one Executor message keyed by a caller-supplied `message_id`, or
  return the item that key already created (#2717).

  A caller whose send timed out cannot know if the first call queued the
  message, so it retries with the same key and gets the same item back. The
  key belongs to one user action: a replay must carry the same target and
  text, or it is refused as a conflict. It never returns a different message.
  """
  @spec enqueue_idempotent(t(), enqueue_attrs()) ::
          {:ok, t(), AgentQueueItem.t(), :accepted | :duplicate} | {:error, {:message_id_conflict, integer()}}
  def enqueue_idempotent(%__MODULE__{} = store, %{message_id: message_id} = attrs) when is_binary(message_id) do
    case find_by_message_id(store, message_id) do
      nil ->
        {store, item} = enqueue(store, attrs)
        {:ok, %{store | item_id_by_message_id: Map.put(store.item_id_by_message_id, message_id, item.id)}, item, :accepted}

      %AgentQueueItem{} = existing ->
        if same_message?(existing, attrs),
          do: {:ok, store, existing, :duplicate},
          else: {:error, {:message_id_conflict, existing.id}}
    end
  end

  @doc "True when `attrs` is a replay of `item`: the same target and the same text."
  @spec same_message?(AgentQueueItem.t(), map()) :: boolean()
  def same_message?(%AgentQueueItem{} = item, attrs) when is_map(attrs) do
    item.target_issue_identifier == Map.get(attrs, :target_issue_identifier) and item.body == Map.get(attrs, :body)
  end

  @spec find_by_message_id(t(), String.t()) :: AgentQueueItem.t() | nil
  def find_by_message_id(%__MODULE__{} = store, message_id) when is_binary(message_id) do
    case Map.get(store.item_id_by_message_id, message_id) do
      nil -> nil
      item_id -> Map.get(store.items, item_id)
    end
  end

  @spec claim_next_deliverable(t(), String.t()) :: {t(), AgentQueueItem.t() | nil}
  def claim_next_deliverable(%__MODULE__{} = store, target_issue_identifier)
      when is_binary(target_issue_identifier) do
    pending_ids = Map.get(store.pending_ids_by_target, target_issue_identifier, [])

    case next_pending_item(store, pending_ids) do
      nil ->
        {store, nil}

      %AgentQueueItem{} = item ->
        claimed_item = %{
          item
          | status: :delivered,
            delivery_attempts: item.delivery_attempts + 1,
            delivered_at: DateTime.utc_now()
        }

        store =
          store
          |> Items.put_item(claimed_item)
          |> Items.remove_pending_id(target_issue_identifier, claimed_item.id)

        {store, claimed_item}
    end
  end

  @spec claim_next_deliverable_matching(t(), String.t(), (AgentQueueItem.t() -> as_boolean(term()))) ::
          {t(), AgentQueueItem.t() | nil}
  def claim_next_deliverable_matching(%__MODULE__{} = store, target_issue_identifier, matcher)
      when is_binary(target_issue_identifier) and is_function(matcher, 1) do
    pending_ids = Map.get(store.pending_ids_by_target, target_issue_identifier, [])

    case next_pending_item_matching(store, pending_ids, matcher) do
      nil ->
        {store, nil}

      %AgentQueueItem{} = item ->
        claimed_item = %{
          item
          | status: :delivered,
            delivery_attempts: item.delivery_attempts + 1,
            delivered_at: DateTime.utc_now()
        }

        store =
          store
          |> Items.put_item(claimed_item)
          |> Items.remove_pending_id(target_issue_identifier, claimed_item.id)

        {store, claimed_item}
    end
  end

  @spec mark_consumed(t(), integer()) :: {t(), AgentQueueItem.t() | nil}
  def mark_consumed(%__MODULE__{} = store, item_id) when is_integer(item_id) do
    Items.update_item(store, item_id, fn item ->
      %{item | status: :consumed, consumed_at: DateTime.utc_now(), failure_reason: nil}
    end)
  end

  @spec restore_pending(t(), integer()) :: {t(), AgentQueueItem.t() | nil}
  def restore_pending(%__MODULE__{} = store, item_id) when is_integer(item_id) do
    case Map.get(store.items, item_id) do
      %AgentQueueItem{target_issue_identifier: target, status: :delivered} = item ->
        updated = %{
          item
          | status: :pending,
            delivered_at: nil,
            provider_delivered_at: nil,
            provider_turn_id: nil,
            failed_at: nil,
            failure_reason: nil
        }

        store =
          store
          |> Items.put_item(updated)
          |> Items.append_pending_id(target, item_id)

        {store, updated}

      %AgentQueueItem{} = item ->
        {store, item}

      nil ->
        {store, nil}
    end
  end

  @spec mark_failed(t(), integer(), term()) :: {t(), AgentQueueItem.t() | nil}
  def mark_failed(%__MODULE__{} = store, item_id, reason) when is_integer(item_id) do
    Items.update_item(store, item_id, fn item ->
      %{item | status: :failed, failed_at: DateTime.utc_now(), failure_reason: reason}
    end)
  end

  @doc false
  @spec restore_failed_pending(t(), integer()) :: {t(), AgentQueueItem.t() | nil}
  def restore_failed_pending(%__MODULE__{} = store, item_id) when is_integer(item_id) do
    case Map.get(store.items, item_id) do
      %AgentQueueItem{target_issue_identifier: target, status: :failed} = item ->
        restored =
          item
          |> Map.put(:status, :pending)
          |> Map.put(:delivered_at, nil)
          |> Map.put(:provider_delivered_at, nil)
          |> Map.put(:provider_turn_id, nil)
          |> Map.put(:failed_at, nil)
          |> Map.put(:failure_reason, nil)

        {store |> Items.put_item(restored) |> Items.append_pending_id(target, item_id), restored}

      %AgentQueueItem{} = item ->
        {store, item}

      nil ->
        {store, nil}
    end
  end

  @spec mark_provider_delivered(t(), integer(), map()) ::
          {t(), AgentQueueItem.t() | nil}
  def mark_provider_delivered(%__MODULE__{} = store, item_id, metadata)
      when is_integer(item_id) and is_map(metadata) do
    Items.update_item(store, item_id, fn item ->
      case item do
        %AgentQueueItem{status: :delivered, provider_delivered_at: nil} ->
          %{
            item
            | provider_delivered_at: DateTime.utc_now(),
              provider_turn_id: provider_turn_id(metadata)
          }

        _other ->
          item
      end
    end)
  end

  @spec mark_superseded(t(), integer()) :: {t(), AgentQueueItem.t() | nil}
  def mark_superseded(%__MODULE__{} = store, item_id) when is_integer(item_id) do
    case Map.get(store.items, item_id) do
      %AgentQueueItem{target_issue_identifier: target, status: :pending} = item ->
        updated = %{item | status: :superseded, superseded_at: DateTime.utc_now()}

        store =
          store
          |> Items.put_item(updated)
          |> Items.remove_pending_id(target, item_id)

        {store, updated}

      %AgentQueueItem{} ->
        Items.update_item(store, item_id, fn item ->
          %{item | status: :superseded, superseded_at: DateTime.utc_now()}
        end)

      nil ->
        {store, nil}
    end
  end

  @spec get(t(), integer()) :: AgentQueueItem.t() | nil
  def get(%__MODULE__{} = store, item_id) when is_integer(item_id), do: Map.get(store.items, item_id)

  @spec find_by_action(t(), String.t()) :: AgentQueueItem.t() | nil
  def find_by_action(%__MODULE__{} = store, action_id) when is_binary(action_id) do
    case Map.get(store.item_id_by_action, action_id) do
      nil -> nil
      item_id -> Map.get(store.items, item_id)
    end
  end

  @spec list_pending(t(), String.t()) :: [AgentQueueItem.t()]
  def list_pending(%__MODULE__{} = store, target_issue_identifier) when is_binary(target_issue_identifier) do
    target_issue_identifier
    |> then(&Map.get(store.pending_ids_by_target, &1, []))
    |> Enum.map(&Map.get(store.items, &1))
    |> Enum.reject(&is_nil/1)
    |> sort_items()
  end

  @spec list_visible_operator_messages(t(), String.t()) :: [AgentQueueItem.t()]
  def list_visible_operator_messages(%__MODULE__{} = store, target_issue_identifier)
      when is_binary(target_issue_identifier) do
    store.items
    |> Map.values()
    |> Enum.filter(fn
      %AgentQueueItem{
        target_issue_identifier: ^target_issue_identifier,
        category: :operator_message,
        status: status
      }
      when status in [:pending, :delivered, :failed] ->
        true

      _ ->
        false
    end)
    |> sort_items()
  end

  @spec consume_delivered(t(), String.t()) :: {t(), [AgentQueueItem.t()]}
  def consume_delivered(%__MODULE__{} = store, target_issue_identifier) when is_binary(target_issue_identifier) do
    Items.update_delivered_items(store, target_issue_identifier, fn item ->
      %{item | status: :consumed, consumed_at: DateTime.utc_now(), failure_reason: nil}
    end)
  end

  @spec restore_delivered(t(), String.t()) :: {t(), [AgentQueueItem.t()]}
  def restore_delivered(%__MODULE__{} = store, target_issue_identifier) when is_binary(target_issue_identifier) do
    Items.update_delivered_items(store, target_issue_identifier, fn item ->
      %{
        item
        | status: :pending,
          delivered_at: nil,
          provider_delivered_at: nil,
          provider_turn_id: nil,
          failed_at: nil,
          failure_reason: nil
      }
    end)
  end

  @spec fail_delivered(t(), String.t(), term()) :: {t(), [AgentQueueItem.t()]}
  def fail_delivered(%__MODULE__{} = store, target_issue_identifier, reason) when is_binary(target_issue_identifier) do
    Items.update_delivered_items(store, target_issue_identifier, fn item ->
      %{item | status: :failed, failed_at: DateTime.utc_now(), failure_reason: reason}
    end)
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
          |> Items.put_item(updated)
          |> Items.remove_pending_id(target, pending_id)

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

  defp next_pending_item_matching(store, pending_ids, matcher) do
    pending_ids
    |> Enum.map(&Map.get(store.items, &1))
    |> Enum.filter(&(match?(%AgentQueueItem{status: :pending}, &1) and matcher.(&1)))
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

  defp provider_turn_id(metadata) do
    case Map.get(metadata, :turn_id) || Map.get(metadata, "turn_id") do
      turn_id when is_binary(turn_id) -> turn_id
      _other -> nil
    end
  end

  @spec enqueue_correlated(t(), enqueue_attrs(), keyword()) ::
          {:ok, t(), AgentQueueItem.t(), :accepted | :duplicate | :retried}
          | {:error, term()}
  defdelegate enqueue_correlated(store, attrs, opts \\ []), to: Aiur.AgentQueueStore.Correlation
end
