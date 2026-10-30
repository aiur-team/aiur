defmodule Aiur.Orchestrator.OperatorMessages.EnqueueNextWorker do
  @moduledoc false

  alias Aiur.{AgentQueue, Orchestrator.LifecycleFence}
  alias Aiur.Orchestrator.OperatorMessages.PendingStore
  alias Aiur.Orchestrator.OperatorMessages.Unread

  @spec enqueue(map(), String.t(), String.t(), map(), function(), function()) ::
          {{:ok, integer()} | {:error, term()}, map()}
  def enqueue(state, identifier, text, request, enqueue_plain, record_evidence) do
    if PendingStore.active_count(state.queue_store) >= PendingStore.capacity() do
      {{:error, {:queue_full, PendingStore.capacity()}}, state}
    else
      enqueue_with_capacity(state, identifier, text, request, enqueue_plain, record_evidence)
    end
  end

  defp enqueue_with_capacity(state, identifier, text, request, enqueue_plain, record_evidence) do
    attrs =
      AgentQueue.operator_message(identifier, text,
        delivery_policy: :checkpoint,
        origin: request.origin,
        actor: request.actor,
        turn_id: request.turn_id,
        action_id: request.action_id,
        correlation: request.correlation,
        persist_across_restart?: true
      )

    case enqueue_plain.(state.queue_store, attrs, request) do
      {:ok, queue_store, item, status} ->
        case PendingStore.save(queue_store) do
          :ok ->
            enqueue_succeeded(state, identifier, queue_store, item, request, status, record_evidence)

          {:error, reason} ->
            {{:error, {:persistence_failed, reason}}, state}
        end

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp enqueue_succeeded(state, identifier, queue_store, item, request, status, record_evidence) do
    Unread.broadcast_change(state.queue_store, queue_store, identifier)
    record_evidence.(item)
    next_state = %{state | queue_store: queue_store} |> LifecycleFence.protect_queued_item(identifier, item)
    result = if request.mode == :correlated, do: %{status: status, item: item}, else: item.id
    {{:ok, result}, next_state}
  end
end
