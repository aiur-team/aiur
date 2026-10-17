defmodule Aiur.DecisionStore.Dispatch do
  @moduledoc false

  require Logger

  alias Aiur.Decision
  alias Aiur.DecisionAnswer
  alias Aiur.DecisionDispatchTasks
  alias Aiur.DecisionStore.Answers
  alias Aiur.DecisionStore.Retry
  alias Aiur.DecisionStore.Settlement

  @decision_dispatch_monitor_retry_ms 25

  @spec reconcile_scheduled_decision(term(), term()) :: term()
  def reconcile_scheduled_decision(%{decision_id: decision_id} = fence, {state, dispatched}) do
    case Answers.fetch_decision(state, decision_id) do
      {:ok, current} ->
        dispatch_current? = dispatch_fence_current?(fence, current, :normal)
        reconcile_queue? = dispatch_current? and fence.request_version == current.version
        reconcile_decision(current, state, dispatch_current?, reconcile_queue?, dispatched)

      {:error, _reason} ->
        {state, dispatched}
    end
  end

  defp reconcile_decision(decision, state, dispatch_current?, reconcile_queue?, dispatched) do
    state = Settlement.ensure_revision_follow_up_required(state, decision)
    current = Map.fetch!(state.current, decision.decision_id)
    state = Settlement.ensure_superseded_revision_follow_ups(state, current)
    current = Map.fetch!(state.current, decision.decision_id)
    state = schedule_revision_follow_up_work(state, current)

    # The pass reports what it scheduled, decision by decision, so that
    # "reconciliation dispatched this answer exactly once" is a claim a caller
    # can read off the report rather than infer from a quiet mailbox. The
    # predicates below are the same ones the schedulers themselves consult, so
    # the report cannot drift from the scheduling it describes.
    dispatched =
      if dispatch_current? and answer_dispatch_schedulable?(state, current, false),
        do: [reconcile_entry(current, :dispatch) | dispatched],
        else: dispatched

    dispatched =
      if reconcile_queue? and queue_reconciliation_schedulable?(state, current),
        do: [reconcile_entry(current, :reconcile_queue) | dispatched],
        else: dispatched

    state = if dispatch_current?, do: maybe_schedule_after_answer(state, current, false), else: state

    # Request enrichment may advance the version without changing delivery state.
    # Pending first delivery can follow it; queued reconciliation cannot.
    state = if reconcile_queue?, do: maybe_schedule_queue_reconciliation(state, current), else: state

    {state, dispatched}
  end

  defp reconcile_entry(decision, kind) do
    %{
      decision_id: decision.decision_id,
      action_id: decision.active_action_id,
      version: decision.version,
      kind: kind
    }
  end

  defp schedule_revision_follow_up_work(state, decision) do
    Enum.reduce(decision.revision_follow_ups, state, fn {action_id, follow_up}, state_acc ->
      if is_nil(follow_up.handled_at),
        do: maybe_schedule_revision_follow_up_projection(state_acc, decision, action_id),
        else: maybe_schedule_revision_follow_up_resolution(state_acc, decision, action_id)
    end)
  end

  @spec maybe_schedule_revision_follow_up_projection(term(), term(), term()) :: term()
  def maybe_schedule_revision_follow_up_projection(state, decision, action_id) do
    key = {decision.decision_id, action_id}

    if MapSet.member?(state.projecting_revision_follow_ups, key) do
      state
    else
      send(self(), {:project_revision_follow_up, decision.decision_id, action_id})
      %{state | projecting_revision_follow_ups: MapSet.put(state.projecting_revision_follow_ups, key)}
    end
  end

  @spec maybe_schedule_revision_follow_up_resolution(term(), term(), term()) :: term()
  def maybe_schedule_revision_follow_up_resolution(state, decision, action_id) do
    key = {decision.decision_id, action_id}

    if MapSet.member?(state.resolving_revision_follow_ups, key) do
      state
    else
      send(self(), {:resolve_revision_follow_up, decision.decision_id, action_id})
      %{state | resolving_revision_follow_ups: MapSet.put(state.resolving_revision_follow_ups, key)}
    end
  end

  @spec start_revision_follow_up_task(term(), term(), term(), term()) :: term()
  def start_revision_follow_up_task(state, operation, decision_id, action_id) do
    case Answers.fetch_decision(state, decision_id) do
      {:ok, decision} ->
        do_start_revision_follow_up_task(state, operation, decision, action_id)

      {:error, _reason} ->
        clear_revision_follow_up_inflight(state, operation, {decision_id, action_id})
    end
  end

  defp do_start_revision_follow_up_task(state, operation, decision, action_id) do
    owner = self()
    callback = revision_follow_up_callback(state, operation)

    task = fn ->
      result = safe_revision_follow_up_call(callback, decision, action_id)
      send(owner, {:revision_follow_up_result, operation, decision.decision_id, action_id, result})
    end

    {:ok, _pid} = Task.start(task)
    state
  end

  defp revision_follow_up_callback(state, :project), do: state.revision_follow_up_projector
  defp revision_follow_up_callback(state, :resolve), do: state.revision_follow_up_resolver

  defp safe_revision_follow_up_call(callback, decision, action_id) do
    case callback.(decision, action_id) do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_result, other}}
    end
  rescue
    error -> {:error, {:callback_crashed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:callback_crashed, {kind, reason}}}
  end

  @spec clear_revision_follow_up_inflight(term(), term(), term()) :: term()
  def clear_revision_follow_up_inflight(state, :project, key) do
    %{state | projecting_revision_follow_ups: MapSet.delete(state.projecting_revision_follow_ups, key)}
  end

  def clear_revision_follow_up_inflight(state, :resolve, key) do
    %{state | resolving_revision_follow_ups: MapSet.delete(state.resolving_revision_follow_ups, key)}
  end

  @spec retry_revision_follow_up?(term(), term(), term(), term()) :: term()
  def retry_revision_follow_up?(state, operation, decision_id, action_id) do
    case Map.get(state.current, decision_id) do
      %Decision{} = decision ->
        case Map.get(decision.revision_follow_ups, action_id) do
          %{handled_at: nil} -> operation == :project
          %{handled_at: %DateTime{}} -> operation == :resolve
          nil -> false
        end

      nil ->
        false
    end
  end

  @spec revision_follow_up_message(term(), term(), term()) :: term()
  def revision_follow_up_message(:project, decision_id, action_id),
    do: {:project_revision_follow_up, decision_id, action_id}

  def revision_follow_up_message(:resolve, decision_id, action_id),
    do: {:resolve_revision_follow_up, decision_id, action_id}

  defp answer_dispatch_schedulable?(state, %Decision{} = decision, retry_failed?) do
    state.writable? and state.health == :writable and Retry.dispatchable?(decision, retry_failed?) and
      answer_free_for_dispatch?(state, decision)
  end

  defp queue_reconciliation_schedulable?(state, %Decision{} = decision) do
    state.writable? and state.health == :writable and Retry.queue_reconcilable?(decision) and answer_free_for_dispatch?(state, decision)
  end

  defp answer_free_for_dispatch?(state, %Decision{} = decision) do
    case Decision.active_answer(decision) do
      nil -> false
      active_answer -> not dispatch_active?(state, active_answer.action_id)
    end
  end

  @spec maybe_schedule_after_answer(term(), term(), term()) :: term()
  def maybe_schedule_after_answer(state, %Decision{} = decision, retry_failed?) do
    if answer_dispatch_schedulable?(state, decision, retry_failed?) do
      schedule_dispatch(state, decision, retry_failed?, state.dispatch_delay_ms)
    end

    state
  end

  defp maybe_schedule_queue_reconciliation(state, %Decision{} = decision) do
    if queue_reconciliation_schedulable?(state, decision) do
      schedule_dispatch_work(state, {:reconcile_queue_action, dispatch_fence(decision)}, 0)
    end

    state
  end

  @spec schedule_dispatch(term(), term(), term(), term()) :: term()
  def schedule_dispatch(state, decision, retry_failed?, delay_ms) do
    schedule_dispatch_work(state, {:dispatch_action, dispatch_fence(decision), retry_failed?}, delay_ms)
  end

  @spec schedule_dispatch_work(term(), term(), term()) :: term()
  def schedule_dispatch_work(state, message, delay_ms) do
    state.dispatch_scheduler.(self(), message, delay_ms)
  end

  @spec dispatch_fences(term()) :: term()
  def dispatch_fences(state) do
    Enum.map(state.current, fn {_decision_id, decision} -> dispatch_fence(decision) end)
  end

  @spec dispatch_fence(term()) :: term()
  def dispatch_fence(decision) do
    %{
      decision_id: decision.decision_id,
      request_version: decision.version,
      lifecycle: dispatch_lifecycle(decision)
    }
  end

  defp dispatch_lifecycle(decision) do
    {
      dispatch_answer_identity(decision),
      decision.active_action_id,
      decision.revision_sequence,
      decision.revision_result,
      decision.decision_status,
      decision.delivery_status,
      dispatch_attempt_identity(decision)
    }
  end

  defp dispatch_attempt_identity(decision) do
    case List.last(Decision.active_dispatch_attempts(decision)) do
      nil ->
        nil

      attempt ->
        {
          attempt.action_id,
          attempt.attempt_id,
          attempt.queue_item_id,
          attempt.run_id,
          attempt.status,
          attempt.failure_reason_class
        }
    end
  end

  defp dispatch_answer_identity(decision) do
    case Decision.active_answer(decision) do
      nil -> nil
      answer -> {answer.action_id, answer.decision_version, answer.content_hash}
    end
  end

  defp dispatch_fence_current?(fence, decision, mode) do
    lifecycle_current? =
      fence.decision_id == decision.decision_id and
        fence.lifecycle == dispatch_lifecycle(decision)

    lifecycle_current? and
      (mode != :reconcile_queue or fence.request_version == decision.version)
  end

  @spec maybe_reconcile_lifecycle_append(term(), term(), term()) :: term()
  def maybe_reconcile_lifecycle_append(state, %{decision_id: decision_id} = fence, action_id) do
    with {:ok, decision} <- Answers.fetch_decision(state, decision_id),
         true <- dispatch_fence_current?(fence, decision, :recover_append),
         %DecisionAnswer{action_id: ^action_id} <- Decision.active_answer(decision),
         true <- Retry.lifecycle_append_failed?(state, action_id) do
      maybe_start_dispatch(state, fence, true, :recover_append)
    else
      _other -> state
    end
  end

  @spec maybe_start_dispatch(term(), term(), term(), term()) :: term()
  def maybe_start_dispatch(state, %{decision_id: decision_id} = fence, retry_failed?, mode \\ :normal) do
    with true <- state.writable? and state.health == :writable,
         true <- decision_dispatch_monitor_live?(state),
         {:ok, decision} <- Answers.fetch_decision(state, decision_id),
         true <- dispatch_fence_current?(fence, decision, mode),
         %DecisionAnswer{} = answer <- Decision.active_answer(decision),
         false <- decision_dispatch_active?(state, decision_id),
         false <- dispatch_active?(state, answer.action_id),
         true <- Retry.dispatch_allowed?(decision, retry_failed?, mode) do
      attempt_id = Retry.next_attempt_id(decision)
      retry_failed? = retry_failed? or Retry.orphan_recovery?(decision)
      dispatch_decision = Retry.decision_for_dispatch(state, decision)
      store = self()
      dispatcher = state.dispatcher

      correlation = %{
        decision_id: decision.decision_id,
        action_id: answer.action_id,
        attempt_id: attempt_id
      }

      operation = fn ->
        safe_dispatch(dispatcher, dispatch_decision, store, attempt_id, retry_failed?)
      end

      callback = fn terminal_correlation, result ->
        send(store, {:dispatch_result, terminal_correlation, result})
      end

      case DecisionDispatchTasks.enqueue(
             decision.ticket.identifier,
             correlation,
             operation,
             callback,
             state.decision_dispatch_tasks,
             owner: store
           ) do
        :pending ->
          put_dispatch(state, correlation)

        {:error, reason} ->
          state
          |> Settlement.settle_dispatch_failure(decision, answer.action_id, attempt_id, reason)
          |> maybe_schedule_superseding_dispatch(decision_id, answer.action_id)
      end
    else
      _other -> state
    end
  end

  defp put_dispatch(state, %{action_id: action_id} = correlation) do
    %{state | dispatching: Map.put(state.dispatching, action_id, correlation)}
  end

  @spec dispatch_active?(term(), term()) :: term()
  def dispatch_active?(state, action_id), do: Map.has_key?(state.dispatching, action_id)

  defp decision_dispatch_active?(state, decision_id) do
    Enum.any?(state.dispatching, fn {_action_id, correlation} ->
      correlation.decision_id == decision_id
    end)
  end

  @spec take_matching_dispatch(term(), term()) :: term()
  def take_matching_dispatch(state, %{action_id: action_id} = correlation) do
    case Map.get(state.dispatching, action_id) do
      ^correlation -> {:ok, %{state | dispatching: Map.delete(state.dispatching, action_id)}}
      _other -> :stale
    end
  end

  @spec fail_interrupted_dispatches(term(), term(), term()) :: term()
  def fail_interrupted_dispatches(state, correlations, reason) do
    Enum.reduce(correlations, state, fn correlation, state_acc ->
      %{decision_id: decision_id, action_id: action_id, attempt_id: attempt_id} = correlation

      state_acc =
        case Answers.fetch_decision(state_acc, decision_id) do
          {:ok, decision} -> Settlement.settle_dispatch_failure(state_acc, decision, action_id, attempt_id, reason)
          {:error, _reason} -> state_acc
        end

      maybe_schedule_superseding_dispatch(state_acc, decision_id, action_id)
    end)
  end

  @spec monitor_decision_dispatch_tasks(term()) :: term()
  def monitor_decision_dispatch_tasks(%{decision_dispatch_monitor_ref: ref} = state)
      when is_reference(ref),
      do: state

  def monitor_decision_dispatch_tasks(state) do
    case decision_dispatch_tasks_pid(state.decision_dispatch_tasks) do
      pid when is_pid(pid) ->
        recovering? = state.decision_dispatch_monitor_reconcile?

        state = %{
          state
          | decision_dispatch_monitor_pid: pid,
            decision_dispatch_monitor_ref: Process.monitor(pid),
            decision_dispatch_monitor_timer: nil,
            decision_dispatch_monitor_reconcile?: false
        }

        if recovering? and state.writable? do
          schedule_dispatch_work(state, {:reconcile_dispatches, dispatch_fences(state)}, 0)
        end

        state

      nil ->
        state
        |> Map.put(:decision_dispatch_monitor_reconcile?, true)
        |> schedule_decision_dispatch_monitor()
    end
  end

  defp decision_dispatch_monitor_live?(%{
         decision_dispatch_monitor_pid: pid,
         decision_dispatch_monitor_ref: ref
       }) do
    is_pid(pid) and is_reference(ref) and Process.alive?(pid)
  end

  @spec with_decision_dispatch_monitor(term(), term(), term()) :: term()
  def with_decision_dispatch_monitor(state, message, dispatch) do
    state = monitor_decision_dispatch_tasks(state)

    if decision_dispatch_monitor_live?(state) do
      dispatch.(state)
    else
      schedule_dispatch_work(state, message, @decision_dispatch_monitor_retry_ms)
      state
    end
  end

  defp decision_dispatch_tasks_pid(server) do
    GenServer.whereis(server)
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  @spec schedule_decision_dispatch_monitor(term()) :: term()
  def schedule_decision_dispatch_monitor(%{decision_dispatch_monitor_timer: timer} = state)
      when is_reference(timer),
      do: state

  def schedule_decision_dispatch_monitor(state) do
    timer = Process.send_after(self(), :monitor_decision_dispatch_tasks, @decision_dispatch_monitor_retry_ms)
    %{state | decision_dispatch_monitor_timer: timer}
  end

  defp safe_dispatch(dispatcher, decision, store, attempt_id, retry_failed?) do
    dispatcher.(decision,
      store: store,
      attempt_id: attempt_id,
      retry_failed: retry_failed?
    )
  rescue
    error ->
      Logger.warning("aiur_decision_store phase=dispatcher_crashed error=#{Exception.message(error)}")
      {:error, :dispatcher_crashed}
  catch
    kind, _reason ->
      Logger.warning("aiur_decision_store phase=dispatcher_crashed kind=#{kind}")
      {:error, :dispatcher_crashed}
  end

  @spec maybe_schedule_superseding_dispatch(term(), term(), term()) :: term()
  def maybe_schedule_superseding_dispatch(state, decision_id, completed_action_id) do
    case Answers.fetch_decision(state, decision_id) do
      {:ok, %Decision{active_action_id: active_action_id} = decision}
      when is_binary(active_action_id) and active_action_id != completed_action_id ->
        maybe_schedule_after_answer(state, decision, false)

      _other ->
        state
    end
  end
end
