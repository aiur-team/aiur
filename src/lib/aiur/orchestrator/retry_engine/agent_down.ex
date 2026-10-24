defmodule Aiur.Orchestrator.RetryEngine.AgentDown do
  @moduledoc "Retry agent exit handling and orphan reaping."

  require Logger

  alias Aiur.AgentPubSub
  alias Aiur.AgentQueueStore
  alias Aiur.Alerts
  alias Aiur.Config
  alias Aiur.Issue
  alias Aiur.Orchestrator.AgentTeardown
  alias Aiur.Orchestrator.ControlLifecycle
  alias Aiur.Orchestrator.ControlLifecycleStore
  alias Aiur.Orchestrator.LifecycleFenceExpiry
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.RetryEngine.PollFailure
  alias Aiur.Orchestrator.RetryEngine.Scheduling
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReport
  alias Aiur.Orchestrator.TokenAccounting

  @spec handle_agent_down(State.t(), reference(), term()) :: {:noreply, State.t()}
  def handle_agent_down(%State{running: running} = state, ref, reason) do
    case State.find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        running_entry = running |> Map.fetch!(issue_id) |> clear_completed_fallback_replacement()
        state = expire_pending_control(state, running_entry, issue_id)
        state = TokenAccounting.record_session_completion_totals(state, running_entry)
        state = state |> maybe_reap_orphaned_agent_shell(running_entry) |> LifecycleFenceExpiry.recover_terminated_input(running_entry)
        session_id = State.running_entry_session_id(running_entry)
        state = handle_running_agent_down(state, issue_id, running_entry, reason, session_id)

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        StatusReport.notify_dashboard(state)
        {:noreply, state}
    end
  end

  defp handle_running_agent_down(
         state,
         issue_id,
         %{runtime_terminal_failure: %{kind: :startup_failed} = failure} = running_entry,
         _reason,
         session_id
       ) do
    reason = Map.get(failure, :reason)

    Logger.warning("Agent startup failed for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling failure retry")

    state
    |> remove_stopped_running_entry(issue_id, running_entry)
    |> Scheduling.schedule_issue_retry(
      issue_id,
      Scheduling.next_retry_attempt_from_running(running_entry),
      runtime_terminal_failure_retry_metadata(running_entry, reason)
    )
  end

  defp handle_running_agent_down(state, issue_id, running_entry, :normal, session_id) do
    if State.completed_running_entry?(running_entry) do
      Logger.info("Completed agent task exited normally for issue_id=#{issue_id} session_id=#{session_id}; parking replaceable entry")
      park_completed_entry(state, issue_id, running_entry)
    else
      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

      state
      |> remove_stopped_running_entry(issue_id, running_entry)
      |> RetryEngine.complete_issue(issue_id)
      |> Scheduling.schedule_issue_retry(issue_id, 1, continuation_retry_metadata(running_entry))
    end
  end

  defp handle_running_agent_down(state, issue_id, running_entry, reason, session_id) do
    if State.completed_running_entry?(running_entry) do
      Logger.warning("Completed agent task exited abnormally for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; preserving completed boundary")
      park_completed_entry(state, issue_id, running_entry)
    else
      Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

      state
      |> remove_stopped_running_entry(issue_id, running_entry)
      |> Scheduling.schedule_issue_retry(issue_id, exit_retry_attempt(running_entry, reason), exit_retry_metadata(running_entry, reason))
    end
  end

  # A local GitHub budget hold in an agent exit reason is definitionally
  # transient: retrying before its own `reset_at` is guaranteed to fail, so the
  # retry is scheduled after `reset_at` and must not consume the ticket's
  # failure retry budget. Without this, a seconds-long hold exhausts
  # `max_retry_attempts` and stamps the ticket `agent:error` — the #2339
  # casualty, where a hold with 97% of the real budget free killed the ticket
  # (#2429). `PollFailure.local_budget_hold_reason/1` is the single extraction used by both
  # this path and retry-poll deferral, so every shape a hold can arrive in
  # (raw, `:local_hold`, legacy transport, workspace preflight wrapper, preflight
  # diagnostic) is treated identically.
  #
  # A hold-caused exit must also leave the failure attempt counter untouched:
  # the retry reuses the attempt this run was dispatched at rather than
  # incrementing it. Incrementing would let repeated holds push the stored
  # attempt above `Config.max_retry_attempts()`, so the *first* genuine failure
  # after them would hit the `next_attempt > max` give-up branch and stamp
  # `agent:error` on attempt one of the real work — the same #2339 casualty,
  # one step removed. A fresh dispatch (`retry_attempt` absent or 0) schedules
  # its first retry at attempt 1, matching the non-hold path.
  defp exit_retry_attempt(running_entry, reason) do
    case PollFailure.local_budget_hold_reason(reason) do
      %{} ->
        case Map.get(running_entry, :retry_attempt) do
          attempt when is_integer(attempt) and attempt > 0 -> attempt
          _ -> 1
        end

      nil ->
        Scheduling.next_retry_attempt_from_running(running_entry)
    end
  end

  defp exit_retry_metadata(running_entry, reason) do
    case PollFailure.local_budget_hold_reason(reason) do
      %{} = hold ->
        running_entry
        |> failure_retry_metadata(reason)
        |> Map.merge(%{delay_type: :local_budget_hold, local_budget_hold: hold})

      nil ->
        failure_retry_metadata(running_entry, reason)
    end
  end

  defp remove_stopped_running_entry(state, issue_id, running_entry) do
    if fallback_replacement?(running_entry) do
      park_failed_fallback_replacement(state, issue_id, running_entry)
    else
      {_running_entry, popped_state} = State.pop_running_entry(state, issue_id)
      popped_state
    end
  end

  defp continuation_retry_metadata(running_entry) do
    issue = Map.get(running_entry, :issue)

    %{
      identifier: running_entry.identifier,
      tracker_identity: Issue.tracker_identity(issue),
      priority: Map.get(issue || %{}, :priority),
      issue_state: Map.get(issue || %{}, :state),
      delay_type: :continuation,
      prior_work: prior_work_for_retry?(running_entry),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      rework_head_sha: Map.get(running_entry, :rework_head_sha)
    }
  end

  defp failure_retry_metadata(running_entry, reason) do
    issue = Map.get(running_entry, :issue)

    %{
      identifier: running_entry.identifier,
      tracker_identity: Issue.tracker_identity(issue),
      priority: Map.get(issue || %{}, :priority),
      issue_state: Map.get(issue || %{}, :state),
      error: "agent exited: #{inspect(reason)}",
      # Structured failure reason retained so retry exhaustion can classify it
      # as a transient infrastructure fault for the #1453 automatic
      # re-dispatch (the formatted `error` string cannot).
      transient_reason: reason,
      prior_work: prior_work_for_retry?(running_entry),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      rework_head_sha: Map.get(running_entry, :rework_head_sha)
    }
  end

  defp runtime_terminal_failure_retry_metadata(running_entry, reason) do
    running_entry
    |> failure_retry_metadata({:startup_failed, reason})
    |> Map.put(:error, "startup failed: #{inspect(reason)}")
    |> Map.put(:last_failure_at, get_in(running_entry, [:runtime_terminal_failure, :observed_at]))
  end

  defp maybe_reap_orphaned_agent_shell(state, running_entry) do
    if State.completed_running_entry?(running_entry) do
      state
    else
      case AgentTeardown.reap_orphaned_agent_shell(running_entry) do
        :reaped ->
          count = Map.get(state, :orphaned_agent_reap_count, 0) + 1
          identifier = Map.get(running_entry, :identifier)

          _ =
            Alerts.emit_custom(
              "ticket.#{identifier}.agent.orphan_reaped",
              "Reaped orphaned agent shell for #{identifier}; orphaned_agent_reap_count=#{count}",
              issue: Map.get(running_entry, :issue),
              workspace: Map.get(running_entry, :workspace_path),
              worker_host: Map.get(running_entry, :worker_host),
              reason: "agent runner exited while its tracked shell process tree remained live",
              needs_attention: true
            )

          %{state | orphaned_agent_reap_count: count}

        :gone ->
          state
      end
    end
  end

  defp expire_pending_control(state, running_entry, issue_id) do
    case ControlLifecycle.current_pending(state.control_lifecycle, issue_id) do
      nil ->
        state

      pending ->
        case ControlLifecycle.expire(state.control_lifecycle, pending.request_id, :worker_unavailable, now: DateTime.utc_now()) do
          {:ok, expired, lifecycle} ->
            :ok = ControlLifecycleStore.save(lifecycle)
            AgentPubSub.broadcast_control_lifecycle(Map.get(running_entry, :identifier), ControlLifecycle.event_payload(expired))
            %{state | control_lifecycle: lifecycle}

          {:ignored, lifecycle} ->
            %{state | control_lifecycle: lifecycle}
        end
    end
  end

  defp park_completed_entry(state, issue_id, running_entry) do
    parked_entry =
      running_entry
      |> Map.put(:pid, nil)
      |> Map.put(:ref, nil)
      |> Map.put(:completion_totals_recorded, true)

    %{
      state
      | running: Map.put(state.running, issue_id, parked_entry),
        completed: MapSet.put(state.completed, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
    |> AgentTeardown.clear_transient_reason_labels(issue_id)
  end

  # Fallback startup can fail after its Task is admitted (for example, a
  # provider rejects a model). Keep the replacement entry parked with the
  # original lifecycle fence, and put only its authoritative failed queue
  # items back to pending before the retry. This prevents the replacement's
  # failure from silently dropping the fenced rework packet.
  defp park_failed_fallback_replacement(state, issue_id, running_entry) do
    queue_store = restore_fenced_failed_items(state.queue_store, Map.get(running_entry, :lifecycle_fence))

    parked_entry =
      running_entry
      |> Map.put(:pid, nil)
      |> Map.put(:ref, nil)
      |> Map.update(:control, %{status: :completed}, &Map.put(&1, :status, :completed))

    %{state | queue_store: queue_store, running: Map.put(state.running, issue_id, parked_entry)}
  end

  defp fallback_replacement?(running_entry), do: Map.get(running_entry, :rate_limit_fallback_replacement) == true

  # The marker protects only a replacement that has not completed any work:
  # its startup exit must retain the lifecycle fence for retry. Once the
  # replacement completes a turn, its next task exit is the pop boundary, so
  # a later dispatch selects the provider from the freshly fetched issue.
  defp clear_completed_fallback_replacement(running_entry) do
    if fallback_replacement?(running_entry) and
         positive_turn_count?(Map.get(running_entry, :completed_turn_count)) do
      Map.delete(running_entry, :rate_limit_fallback_replacement)
    else
      running_entry
    end
  end

  defp restore_fenced_failed_items(queue_store, %{pending_item_ids: %MapSet{} = item_ids}) do
    Enum.reduce(item_ids, queue_store, fn item_id, store ->
      {next_store, _item} = AgentQueueStore.restore_failed_pending(store, item_id)
      next_store
    end)
  end

  defp restore_fenced_failed_items(queue_store, _fence), do: queue_store

  @spec prior_work_for_retry?(map(), boolean()) :: boolean()
  def prior_work_for_retry?(running_entry, continuation_enabled? \\ Config.agent_prior_work_continuation?())
      when is_map(running_entry) and is_boolean(continuation_enabled?) do
    continuation_enabled? and
      (Map.get(running_entry, :prior_work, false) == true or
         positive_turn_count?(Map.get(running_entry, :completed_turn_count)))
  end

  defp positive_turn_count?(turn_count), do: is_integer(turn_count) and turn_count > 0
end
