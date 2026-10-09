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

    # A completed provider cannot drain its claims; let its replacement retry them.
    queue_store =
      if State.completed_provenance?(entry) do
        Enum.reduce(ids, state.queue_store, &restore_unacknowledged_claim/2)
      else
        state.queue_store
      end

    %{state | queue_store: queue_store, running: Map.put(state.running, issue_id, Map.delete(entry, :lifecycle_fence))}
  end

  defp restore_unacknowledged_claim(id, store) do
    case AgentQueueStore.get(store, id) do
      %AgentQueueItem{provider_delivered_at: nil, status: :delivered} -> elem(AgentQueueStore.restore_pending(store, id), 0)
      %AgentQueueItem{provider_delivered_at: nil, status: :failed} -> elem(AgentQueueStore.restore_failed_pending(store, id), 0)
      _ -> store
    end
  end
end
