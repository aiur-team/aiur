defmodule Aiur.Orchestrator.OperatorMessages.EnqueueNextWorker do
  @moduledoc false

  alias Aiur.{AgentQueue, Orchestrator.LifecycleFence}
  alias Aiur.Orchestrator.OperatorMessages.Unread

  def enqueue(state, identifier, text, request, enqueue_plain, record_evidence) do
    attrs =
      AgentQueue.operator_message(identifier, text,
        delivery_policy: :checkpoint,
        origin: request.origin,
        actor: request.actor,
        turn_id: request.turn_id,
        action_id: request.action_id,
        correlation: request.correlation
      )

    case enqueue_plain.(state.queue_store, attrs, request) do
      {:ok, queue_store, item, _status} ->
        Unread.broadcast_change(state.queue_store, queue_store, identifier)
        record_evidence.(item)
        next_state = %{state | queue_store: queue_store} |> LifecycleFence.protect_queued_item(identifier, item)
        {{:ok, item.id}, next_state}

      {:error, _reason} = error ->
        {error, state}
    end
  end
end
