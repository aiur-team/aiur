defmodule Aiur.Orchestrator.OperatorMessages.EnqueueNextWorker do
  @moduledoc false

  alias Aiur.{AgentQueue, Orchestrator.LifecycleFence}
  alias Aiur.Orchestrator.Lifecycle
  alias Aiur.Orchestrator.OperatorMessages.PendingStore
  alias Aiur.Orchestrator.OperatorMessages.Unread

  @spec enqueue(Aiur.Orchestrator.State.t(), String.t(), String.t(), map(), function(), function(), keyword()) ::
          {{:ok, integer()} | {:error, term()}, map()}
  def enqueue(state, identifier, text, request, enqueue_plain, record_evidence, opts \\ []) do
    if PendingStore.active_count(state.queue_store) >= PendingStore.capacity() do
      {{:error, {:queue_full, PendingStore.capacity()}}, state}
    else
      enqueue_with_capacity(state, identifier, text, request, enqueue_plain, record_evidence, opts)
    end
  end

  defp enqueue_with_capacity(state, identifier, text, request, enqueue_plain, record_evidence, opts) do
    attrs =
      AgentQueue.operator_message(identifier, text,
        delivery_policy: :checkpoint,
        origin: request.origin,
        actor: request.actor,
        turn_id: request.turn_id,
        action_id: request.action_id,
        correlation: request.correlation,
        # Executor messages persist too: a pin swap restarts the daemon, and a
        # message waiting for the next Executor session must survive it. Hook
        # delivery saves the item as delivered before the Executor sees it, so
        # a restart never sends it twice.
        persist_across_restart?: true
      )

    case enqueue_plain.(state.queue_store, attrs, request) do
      {:ok, queue_store, item, status} ->
        case PendingStore.save(queue_store) do
          :ok ->
            enqueue_succeeded(state, identifier, queue_store, item, request, status, record_evidence, opts)

          {:error, reason} ->
            {{:error, {:persistence_failed, reason}}, state}
        end

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp enqueue_succeeded(state, identifier, queue_store, item, request, status, record_evidence, opts) do
    Unread.broadcast_change(state.queue_store, queue_store, identifier)
    record_evidence.(item)
    next_state = %{state | queue_store: queue_store} |> LifecycleFence.protect_queued_item(identifier, item)

    next_state =
      if status == :accepted and correlated_answer?(request) do
        redispatch = Keyword.get(opts, :redispatch_fun, &redispatch/2)
        redispatch.(next_state, identifier)
      else
        next_state
      end

    result = if request.mode == :correlated, do: %{status: status, item: item}, else: item.id
    {{:ok, result}, next_state}
  end

  defp correlated_answer?(%{mode: :correlated, correlation: %{decision_id: id}}) when is_binary(id), do: true
  defp correlated_answer?(_request), do: false

  defp redispatch(state, identifier) do
    {:reply, _result, next_state} = Lifecycle.note_queued_demand(state, [identifier])
    next_state
  end
end
