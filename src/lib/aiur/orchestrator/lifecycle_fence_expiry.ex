defmodule Aiur.Orchestrator.LifecycleFenceExpiry do
  @moduledoc "Bounds provider-delivery fences without discarding their queued input."

  require Logger

  alias Aiur.{AgentQueueItem, AgentQueueStore, Alerts}
  alias Aiur.Orchestrator.{LifecycleFence, State}

  @timeout_seconds 120

  @spec reconcile(State.t(), DateTime.t()) :: State.t()
  def reconcile(%State{} = state, now \\ DateTime.utc_now()) do
    Enum.reduce(state.running, state, fn {issue_id, entry}, current ->
      reconcile_entry(current, issue_id, entry, now)
    end)
  end

  defp reconcile_entry(state, issue_id, entry, now) do
    case LifecycleFence.fence_for_entry(entry) do
      %{opened_at: %DateTime{} = opened_at} = fence ->
        if DateTime.diff(now, opened_at, :second) >= @timeout_seconds,
          do: release(state, issue_id, entry, fence),
          else: state

      _ ->
        state
    end
  end

  defp release(state, issue_id, entry, fence) do
    ids = Enum.sort(fence.pending_item_ids)
    identifier = entry.identifier
    reason = "Provider delivery fence expired after #{@timeout_seconds}s; pending_item_ids=#{inspect(ids)}. Lifecycle reconciliation may proceed; delivery is unconfirmed."
    Logger.warning("#{State.issue_context(entry.issue)} #{reason}")

    Alerts.emit_system("ticket.#{identifier}.agent.lifecycle_fence_expired",
      issue: identifier,
      message: reason,
      reason: reason,
      needs_attention: true,
      severity: "warning"
    )

    # Retry failed input; only a completed provider's in-flight claims can be reclaimed.
    completed? = State.completed_provenance?(entry)
    queue_store = Enum.reduce(ids, state.queue_store, &restore_unacknowledged_claim(&1, &2, completed?))

    entry = entry |> Map.delete(:lifecycle_fence) |> Map.update(:expired_lifecycle_item_ids, MapSet.new(ids), &MapSet.union(&1, MapSet.new(ids)))
    %{state | queue_store: queue_store, running: Map.put(state.running, issue_id, entry)}
  end

  @doc "Recover expired claims only after their provider has been terminated."
  @spec recover_terminated_input(State.t(), map()) :: State.t()
  def recover_terminated_input(state, entry) do
    ids = Map.get(entry, :expired_lifecycle_item_ids, MapSet.new())
    queue_store = Enum.reduce(ids, state.queue_store, &restore_unacknowledged_claim(&1, &2, true))
    %{state | queue_store: queue_store}
  end

  defp restore_unacknowledged_claim(id, store, completed?) do
    case AgentQueueStore.get(store, id) do
      %AgentQueueItem{provider_delivered_at: nil, status: :delivered} when completed? -> elem(AgentQueueStore.restore_pending(store, id), 0)
      %AgentQueueItem{provider_delivered_at: nil, status: :failed} -> elem(AgentQueueStore.restore_failed_pending(store, id), 0)
      _ -> store
    end
  end
end
