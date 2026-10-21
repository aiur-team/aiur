defmodule Aiur.DecisionStore.Info do
  @moduledoc false

  require Logger

  alias Aiur.Decision
  alias Aiur.DecisionPubSub
  alias Aiur.DecisionStore.AppendRecovery
  alias Aiur.DecisionStore.Audit
  alias Aiur.DecisionStore.Boot
  alias Aiur.DecisionStore.Dispatch
  alias Aiur.DecisionStore.FailureAttention
  alias Aiur.DecisionStore.Persistence
  alias Aiur.DecisionStore.Settlement

  @spec handle_info(term(), term()) :: term()
  def handle_info(:repair_decision_projection, state) do
    if state.projection_retry, do: Process.cancel_timer(state.projection_retry)
    {:noreply, Persistence.repair_projection(%{state | projection_retry: nil})}
  end

  def handle_info(:decision_projection_recovered, state), do: Boot.handle_continue(:schedule_reconciliation, state)

  def handle_info({:retry_executor_request_notification, decision_id, version, attempt}, state) do
    case Map.get(state.current, decision_id) do
      %Decision{version: ^version, decision_status: status} = decision when status in [:open, :deferred] ->
        Audit.notify_requested_executor(decision, state, :executor_request_reconciler, attempt)

      _terminal_or_replaced ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(message, %{writable?: false} = state)
      when is_tuple(message) and
             elem(message, 0) in [
               :dispatch_action,
               :reconcile_queue_action,
               :reconcile_lifecycle_append,
               :reconcile_dispatches,
               :dispatch_result,
               :project_revision_follow_up,
               :resolve_revision_follow_up
             ] do
    {:noreply, %{state | held_journal_work: [message | state.held_journal_work]}}
  end

  def handle_info({:reconcile_dispatches, fences}, state) do
    {next_state, dispatched} =
      Enum.reduce(fences, {state, []}, &Dispatch.reconcile_scheduled_decision/2)

    DecisionPubSub.broadcast_dispatches_reconciled(self(), length(fences), Enum.reverse(dispatched))

    {:noreply, next_state}
  end

  def handle_info({:dispatch_action, fence, retry_failed?} = message, state) do
    {:noreply,
     Dispatch.with_decision_dispatch_monitor(state, message, fn monitored_state ->
       Dispatch.maybe_start_dispatch(monitored_state, fence, retry_failed?)
     end)}
  end

  def handle_info({:reconcile_queue_action, fence} = message, state) do
    {:noreply,
     Dispatch.with_decision_dispatch_monitor(state, message, fn monitored_state ->
       Dispatch.maybe_start_dispatch(monitored_state, fence, false, :reconcile_queue)
     end)}
  end

  def handle_info({:retry_follow_up_append, key}, state) do
    {:noreply, AppendRecovery.retry_pending_follow_up(state, key)}
  end

  def handle_info({:reconcile_lifecycle_append, fence, action_id} = message, state) do
    {:noreply,
     Dispatch.with_decision_dispatch_monitor(state, message, fn monitored_state ->
       Dispatch.maybe_reconcile_lifecycle_append(monitored_state, fence, action_id)
     end)}
  end

  def handle_info(
        {:dispatch_result, %{decision_id: decision_id, action_id: action_id, attempt_id: attempt_id} = correlation, result},
        state
      ) do
    case Dispatch.take_matching_dispatch(state, correlation) do
      {:ok, state} ->
        state = Settlement.settle_dispatch(state, decision_id, action_id, attempt_id, result)
        {:noreply, Dispatch.maybe_schedule_superseding_dispatch(state, decision_id, action_id)}

      :stale ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{decision_dispatch_monitor_ref: ref, decision_dispatch_monitor_pid: pid} = state
      ) do
    interrupted = Map.values(state.dispatching)

    state =
      state
      |> Map.merge(%{
        dispatching: %{},
        decision_dispatch_monitor_pid: nil,
        decision_dispatch_monitor_ref: nil,
        decision_dispatch_monitor_reconcile?: true
      })
      |> Dispatch.fail_interrupted_dispatches(interrupted, :decision_dispatch_coordinator_exit)
      |> Dispatch.schedule_decision_dispatch_monitor()

    {:noreply, state}
  end

  def handle_info(:monitor_decision_dispatch_tasks, state) do
    {:noreply, Dispatch.monitor_decision_dispatch_tasks(%{state | decision_dispatch_monitor_timer: nil})}
  end

  def handle_info({:failure_attention_reprojection_complete, result, failed}, state) do
    state = FailureAttention.complete_failure_attention_reprojection(state, result, failed)
    Logger.debug("aiur_decision_store phase=failure_attention_reprojection_complete count=#{length(failed)}")
    Enum.each(state.failure_attention_reprojection_waiters, &GenServer.reply(&1, :ok))

    {:noreply, %{state | failure_attention_reprojection_pending?: false, failure_attention_reprojection_waiters: []}}
  end

  def handle_info({:project_revision_follow_up, decision_id, action_id}, state) do
    {:noreply, Dispatch.start_revision_follow_up_task(state, :project, decision_id, action_id)}
  end

  def handle_info({:resolve_revision_follow_up, decision_id, action_id}, state) do
    {:noreply, Dispatch.start_revision_follow_up_task(state, :resolve, decision_id, action_id)}
  end

  def handle_info({:revision_follow_up_result, operation, decision_id, action_id, :ok}, state) do
    {:noreply, Dispatch.clear_revision_follow_up_inflight(state, operation, {decision_id, action_id})}
  end

  def handle_info({:revision_follow_up_result, operation, decision_id, action_id, {:error, reason}}, state) do
    key = {decision_id, action_id}

    if Dispatch.retry_revision_follow_up?(state, operation, decision_id, action_id) do
      Logger.warning(
        "aiur_decision_store phase=revision_follow_up_#{operation}_failed " <>
          "decision_id=#{decision_id} action_id=#{action_id} reason=#{inspect(reason)}"
      )

      message = Dispatch.revision_follow_up_message(operation, decision_id, action_id)
      Process.send_after(self(), message, state.reconcile_delay_ms)
      {:noreply, state}
    else
      {:noreply, Dispatch.clear_revision_follow_up_inflight(state, operation, key)}
    end
  end
end
