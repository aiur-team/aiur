defmodule Aiur.AgentQueueStore.Correlation do
  @moduledoc false
  alias Aiur.AgentQueueItem
  alias Aiur.AgentQueueStore
  import Aiur.AgentQueueStore.Items, only: [put_item: 2, append_pending_id: 3]

  @doc """
  Enqueue one action-correlated item, or return the existing snapshot for
  an exact replay in any state. A conflicting payload never mutates the
  store. `retry_failed: true` restores the same failed item once.
  """
  @spec enqueue_correlated(AgentQueueStore.t(), AgentQueueStore.enqueue_attrs(), keyword()) ::
          {:ok, AgentQueueStore.t(), AgentQueueItem.t(), :accepted | :duplicate | :retried}
          | {:error, term()}
  def enqueue_correlated(%AgentQueueStore{} = store, attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with {:ok, action_id} <- validate_correlation(attrs) do
      case AgentQueueStore.find_by_action(store, action_id) do
        nil ->
          {store, item} = AgentQueueStore.enqueue(store, attrs)
          indexed_store = %{store | item_id_by_action: Map.put(store.item_id_by_action, action_id, item.id)}
          {:ok, indexed_store, item, :accepted}

        %AgentQueueItem{} = existing ->
          replay_correlated(store, existing, attrs, Keyword.get(opts, :retry_failed, false))
      end
    end
  end

  defp validate_correlation(attrs) do
    action_id = Map.get(attrs, :action_id)
    correlation = Map.get(attrs, :correlation)

    cond do
      not (is_binary(action_id) and action_id != "") -> {:error, :missing_action_id}
      not is_map(correlation) -> {:error, :missing_correlation}
      Map.get(correlation, :action_id, Map.get(correlation, "action_id")) != action_id -> {:error, :action_mismatch}
      true -> {:ok, action_id}
    end
  end

  defp replay_correlated(store, existing, attrs, retry_failed?) do
    if correlated_fingerprint(existing) == correlated_fingerprint(attrs) do
      maybe_retry_failed(store, existing, retry_failed?)
    else
      {:error, {:idempotency_conflict, existing.action_id}}
    end
  end

  defp maybe_retry_failed(store, %AgentQueueItem{status: :failed} = existing, true) do
    restored = %{
      existing
      | status: :pending,
        delivery_attempts: 0,
        delivered_at: nil,
        provider_delivered_at: nil,
        provider_turn_id: nil,
        failed_at: nil,
        failure_reason: nil
    }

    next_store =
      store
      |> put_item(restored)
      |> append_pending_id(restored.target_issue_identifier, restored.id)

    {:ok, next_store, restored, :retried}
  end

  defp maybe_retry_failed(store, existing, _retry_failed?), do: {:ok, store, existing, :duplicate}

  defp correlated_fingerprint(%AgentQueueItem{} = item) do
    correlated_fingerprint(%{
      target_issue_identifier: item.target_issue_identifier,
      source: item.source,
      category: item.category,
      event_type: item.event_type,
      body: item.body,
      delivery: item.delivery,
      action_id: item.action_id,
      correlation: item.correlation,
      causal_refs: item.causal_refs
    })
  end

  defp correlated_fingerprint(attrs) when is_map(attrs) do
    material = %{
      target_issue_identifier: Map.get(attrs, :target_issue_identifier),
      source: Map.get(attrs, :source),
      category: Map.get(attrs, :category),
      event_type: Map.get(attrs, :event_type),
      body: Map.get(attrs, :body),
      delivery: normalize_delivery(Map.get(attrs, :delivery, %{})),
      action_id: Map.get(attrs, :action_id),
      correlation: stable_correlation(Map.get(attrs, :correlation)),
      causal_refs: Map.get(attrs, :causal_refs, [])
    }

    material
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp stable_correlation(correlation) when is_map(correlation) do
    correlation
    |> Map.delete(:attempt_id)
    |> Map.delete("attempt_id")
  end

  defp stable_correlation(correlation), do: correlation

  @doc false
  @spec normalize_delivery(term()) :: term()
  def normalize_delivery(delivery) when is_map(delivery) do
    %{
      priority: Map.get(delivery, :priority, :next),
      durability: Map.get(delivery, :durability, :durable),
      consume_at: Map.get(delivery, :consume_at, :safe_checkpoint),
      interrupt_requested: Map.get(delivery, :interrupt_requested, false),
      # `:immediate` is the REPL deliver-now flag (claude-repl pastes Executor
      # messages into the live pane mid-turn). Dropping it here silently
      # downgraded every immediate message to checkpoint delivery, so a
      # claude-repl agent on a long turn never received Executor input.
      immediate: Map.get(delivery, :immediate, false),
      fallback: Map.get(delivery, :fallback)
    }
  end
end
