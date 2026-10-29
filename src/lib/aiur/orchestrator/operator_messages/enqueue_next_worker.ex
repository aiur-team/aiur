defmodule Aiur.Orchestrator.OperatorMessages.EnqueueNextWorker do
  @moduledoc false

  alias Aiur.{AgentQueue, Orchestrator.LifecycleFence}
  alias Aiur.Orchestrator.OperatorMessages.PendingStore
  alias Aiur.Orchestrator.OperatorMessages.Unread

  @spec enqueue(map(), String.t(), String.t(), map(), function(), function()) ::
          {{:ok, integer()} | {:error, term()}, map()}
  def enqueue(state, identifier, text, request, enqueue_plain, record_evidence) do
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
      {:ok, queue_store, item, _status} ->
        try do
          :ok = PendingStore.save!(queue_store)
        rescue
          error ->
            {{:error, {:persistence_failed, Exception.message(error)}}, state}
        else
          :ok -> enqueue_succeeded(state, identifier, queue_store, item, record_evidence)
        end

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp enqueue_succeeded(state, identifier, queue_store, item, record_evidence) do
    Unread.broadcast_change(state.queue_store, queue_store, identifier)
    record_evidence.(item)
    next_state = %{state | queue_store: queue_store} |> LifecycleFence.protect_queued_item(identifier, item)
    {{:ok, item.id}, next_state}
  end
end
