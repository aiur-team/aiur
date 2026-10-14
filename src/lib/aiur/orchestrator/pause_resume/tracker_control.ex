defmodule Aiur.Orchestrator.PauseResume.TrackerControl do
  @moduledoc """
  Runs operator resume and dispatch-budget reset controls as tracker steps outside the orchestrator call.
  """

  alias Aiur.Alerts
  alias Aiur.Config
  alias Aiur.Issue
  alias Aiur.Orchestrator.ControlLifecycle
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.Parking
  alias Aiur.Orchestrator.PauseResume.CompletedReplacement
  alias Aiur.Orchestrator.PauseResume.ControlCalls
  alias Aiur.Orchestrator.PauseResume.DeclineReason
  alias Aiur.Orchestrator.PauseResume.QueuedDispatch
  alias Aiur.Orchestrator.PauseResume.Resume
  alias Aiur.Orchestrator.RemoteControlMode
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReport
  alias Aiur.Orchestrator.TicketTransition
  alias Aiur.Tracker
  require Logger

  defp reset_alert_issue_id(%State{} = state, issue_identifier) do
    case find_issue_id_by_identifier(state, issue_identifier) do
      {:ok, issue_id} -> issue_id
      {:error, _reason} -> issue_identifier
    end
  end

  defp reply_for_reset(state, issue, alert_issue_id, issue_identifier, :ok) do
    Logger.info("Lifetime dispatch budget reset: issue_identifier=#{issue_identifier} issue_id=#{issue.id}")
    emit_reset_success_alert(alert_issue_id, issue_identifier)
    StatusReport.notify_dashboard(state)
    {:reply, {:ok, :reset}, state}
  end

  defp reply_for_reset(state, _issue, alert_issue_id, issue_identifier, {:error, reason}) do
    Logger.error("Lifetime dispatch budget reset failed (durable store): issue_identifier=#{issue_identifier} reason=#{inspect(reason)}")

    emit_reset_failure_alert(alert_issue_id, issue_identifier, {:budget_reset_failed, reason})
    {:reply, {:error, {:budget_reset_failed, reason}}, state}
  end

  defp emit_reset_success_alert(alert_issue_id, issue_identifier) do
    Alerts.emit_custom(
      "ticket.#{alert_issue_id}.agent.attention.dispatch-budget-reset.resolved",
      "Lifetime dispatch budget reset completed for #{issue_identifier}.",
      issue: alert_issue_id,
      reason: "The lifetime dispatch budget reset completed.",
      needs_attention: false,
      severity: "info",
      event_source: :system
    )
  end

  defp emit_reset_failure_alert(alert_issue_id, issue_identifier, reason) do
    Alerts.emit_custom(
      "ticket.#{alert_issue_id}.agent.attention.dispatch-budget-reset",
      "Lifetime dispatch budget reset failed for #{issue_identifier}: #{inspect(reason)}.",
      issue: alert_issue_id,
      reason: "The lifetime dispatch budget reset failed: #{inspect(reason)}",
      needs_attention: true,
      severity: "warning",
      event_source: :system
    )
  end

  @doc false
  @spec find_issue_id_by_identifier(State.t(), term()) :: term()
  def find_issue_id_by_identifier(%State{} = state, issue_identifier) do
    case Enum.find(state.last_polled_issues, fn
           {issue_id, %Issue{identifier: identifier}} ->
             Issue.identifier_matches?(issue_id, identifier, issue_identifier)

           _ ->
             false
         end) do
      {issue_id, _issue} -> {:ok, issue_id}
      nil -> {:error, :unknown_issue}
    end
  end

  # Tracker reads and writes run in the control caller, between short serialized
  # state transitions; a slow tracker must not hold the Orchestrator mailbox.
  @doc false
  @spec tracker_control_call(State.t(), atom(), String.t(), term(), term()) :: {:reply, term(), State.t()}
  def tracker_control_call(state, action, identifier, stage \\ :start, result \\ nil) do
    ControlCalls.guard_control_call(state, action, identifier, fn ->
      tracker_control_step(state, action, identifier, stage, result)
    end)
  end

  defp tracker_control_step(state, :reset_budget, identifier, :start, _) do
    case find_issue_id_by_identifier(state, identifier) do
      {:ok, issue_id} ->
        reset_resolved_issue(state, identifier, Map.fetch!(state.last_polled_issues, issue_id))

      {:error, :unknown_issue} ->
        tracker_io(state, :reset_budget, identifier, :fetched, :fetch_issue_states_by_ids, [[identifier]])
    end
  end

  defp tracker_control_step(state, :reset_budget, identifier, :fetched, result) do
    case result do
      {:ok, [%Issue{} = issue | _]} ->
        state = put_in(state.last_polled_issues[issue.id], issue)
        reset_resolved_issue(state, identifier, issue)

      other ->
        reason = tracker_refresh_error(other, :unknown_issue)
        emit_reset_failure_alert(reset_alert_issue_id(state, identifier), identifier, reason)
        {:reply, {:error, reason}, state}
    end
  end

  defp tracker_control_step(state, :reset_budget, identifier, {:restored, issue}, result) do
    case result do
      :ok ->
        # A poll or another control may have updated the issue while the write ran.
        state = if state.last_polled_issues[issue.id] == issue, do: put_in(state.last_polled_issues[issue.id], %{issue | state: "todo"}), else: state
        reply_for_reset(state, issue, issue.id, identifier, :ok)

      {:error, reason} ->
        emit_reset_failure_alert(issue.id, identifier, {:state_restore_failed, reason})
        {:reply, {:error, {:state_restore_failed, reason}}, state}
    end
  end

  # Global-hold-wins: while the daemon is globally paused, an individual resume
  # cannot override the single switch. Unpause the daemon to resume agents.
  defp tracker_control_step(%State{globally_paused: true} = state, action, _identifier, _stage, _result)
       when action in [:resume, :resume_with_receipt],
       do: {:reply, {:error, :globally_paused}, state}

  defp tracker_control_step(state, action, identifier, :start, _) when action in [:resume, :resume_with_receipt] do
    case State.find_running_by_identifier(state.running, identifier) do
      %{issue: %Issue{} = issue} = entry ->
        Parking.running_control(state, action, identifier, entry, issue, &tracker_io/6, &resume_control_reply/4)

      nil ->
        case find_issue_id_by_identifier(state, identifier) do
          {:ok, issue_id} ->
            cached = Map.fetch!(state.last_polled_issues, issue_id)
            tracker_io(state, action, identifier, {:queued_fetched, cached}, :fetch_issue_states_by_ids, [[issue_id]])

          {:error, :unknown_issue} ->
            {:reply, {:error, :no_running_agent}, state}
        end

      entry ->
        resume_control_reply(state, action, identifier, entry)
    end
  end

  defp tracker_control_step(state, action, identifier, {:running_cleared, issue_id, ref}, result) do
    case {result, State.find_running_by_identifier(state.running, identifier)} do
      {:ok, %{issue: %Issue{id: ^issue_id} = issue, ref: ^ref} = entry} ->
        issue = cleared_pause_issue(issue)
        entry = Map.put(entry, :issue, issue)
        state = Resume.put_running_entry(state, issue_id, entry)

        if Issue.parked?(issue),
          do: tracker_io(state, action, identifier, {:running_unparked, issue_id, ref}, :remove_label, [issue.identifier, "#{Config.settings!().tracker.github.label_prefix}:parked"]),
          else: resume_control_reply(state, action, identifier, entry)

      {{:error, reason}, _entry} ->
        {:reply, {:error, {:pause_override_clear_failed, reason}}, state}

      {:ok, _changed_entry} ->
        {:reply, {:error, :no_running_agent}, state}
    end
  end

  defp tracker_control_step(state, action, identifier, {:running_unparked, _, _} = stage, result),
    do: Parking.running_marker_result(state, action, identifier, stage, result, &Resume.put_running_entry/3, &resume_control_reply/4)

  defp tracker_control_step(state, action, identifier, {:completed_refreshed, issue_id, ref}, result) do
    case State.find_running_by_identifier(state.running, identifier) do
      %{issue: %Issue{id: ^issue_id}, ref: ^ref} = entry ->
        if State.completed_provenance?(entry) do
          finish_resume_control(action, identifier, CompletedReplacement.restart_revalidated_completed_issue(state, entry, result))
        else
          {:reply, {:error, :no_running_agent}, state}
        end

      _changed_entry ->
        {:reply, {:error, :no_running_agent}, state}
    end
  end

  defp tracker_control_step(state, action, identifier, {:queued_fetched, cached}, result) do
    case result do
      {:ok, [%Issue{id: issue_id} = issue | _]} when issue_id == cached.id ->
        state = put_in(state.last_polled_issues[issue.id], issue)

        case QueuedDispatch.queued_issue_resumability(state, issue) do
          :ok ->
            refresh_queued_resume(state, action, identifier, issue)

          {:error, reason} ->
            {:reply, {:error, QueuedDispatch.maybe_stale_tracker_reason(reason, cached, issue)}, state}
        end

      other ->
        state = if other == {:ok, []} and state.last_polled_issues[cached.id] == cached, do: %{state | last_polled_issues: Map.delete(state.last_polled_issues, cached.id)}, else: state
        {:reply, {:error, tracker_refresh_error(other, :tracker_issue_not_found)}, state}
    end
  end

  defp tracker_control_step(state, action, identifier, {:queued_cleared, issue}, :ok) do
    cleared = cleared_pause_issue(issue)
    state = if state.last_polled_issues[issue.id] == issue, do: put_in(state.last_polled_issues[issue.id], cleared), else: state
    tracker_io(state, action, identifier, {:queued_refreshed, cleared}, :fetch_issue_states_by_ids, [[issue.id]])
  end

  defp tracker_control_step(state, _action, _identifier, {:queued_cleared, _issue}, {:error, reason}),
    do: {:reply, {:error, {:pause_override_clear_failed, reason}}, state}

  defp tracker_control_step(state, _action, _identifier, {:queued_refreshed, cleared}, result) do
    case result do
      {:ok, [%Issue{id: issue_id} = issue | _]} when issue_id == cleared.id ->
        state = put_in(state.last_polled_issues[issue.id], issue)

        {reply, state} =
          case DispatchPolicy.manual_resume_decision(issue, state) do
            :dispatch -> Dispatcher.dispatch_prevalidated_issue(state, issue)
            {:skip, reason} -> {{:error, QueuedDispatch.maybe_stale_tracker_reason(DeclineReason.resume_decline_reason(reason, issue, state), cleared, issue)}, state}
          end

        StatusReport.notify_dashboard(state)
        {:reply, reply, state}

      other ->
        state = if other == {:ok, []} and state.last_polled_issues[cleared.id] == cleared, do: %{state | last_polled_issues: Map.delete(state.last_polled_issues, cleared.id)}, else: state
        {:reply, {:error, tracker_refresh_error(other, :tracker_issue_not_found)}, state}
    end
  end

  defp refresh_queued_resume(state, action, identifier, issue) do
    if Issue.paused?(issue) do
      tracker_io(state, action, identifier, {:queued_cleared, issue}, :remove_label, [issue.identifier, Resume.pause_override_label()])
    else
      tracker_io(state, action, identifier, {:queued_refreshed, issue}, :fetch_issue_states_by_ids, [[issue.id]])
    end
  end

  # A lifetime-latched ticket is durably moved to `agent:error` when it trips
  # (`Dispatcher.persist_lifetime_trip/3`), and `error` is not an active state —
  # so clearing the budget alone leaves the ticket undispatchable. Restore a
  # latched error ticket to `todo` (the "pick it up again" state) so
  # `reset-budget` actually returns it to the board (#1453 review P2c).
  #
  # The restore deliberately writes `todo`, never `rework`: a lifetime dispatch
  # latch is an exhaustion of retry budget, not a reviewer's rejection, so a
  # `rework` verdict would be a lie — and on a ticket with no open PR it would
  # strand the ticket in a state nothing selects (#2075).
  defp reset_resolved_issue(state, identifier, issue) do
    latched? = match?({:lifetime, _, _}, Dispatcher.dispatch_latch_status(state, issue.id))
    {state, result} = Dispatcher.reset_lifetime_budget(state, issue.id)

    if result == :ok and latched? and DispatchPolicy.normalize_issue_state(issue.state) == "error" do
      tracker_io(state, :reset_budget, identifier, {:restored, issue}, :update_issue_state, [issue.identifier, "todo"])
    else
      reply_for_reset(state, issue, issue.id, identifier, result)
    end
  end

  defp resume_control_reply(state, action, identifier, entry) do
    if State.completed_provenance?(entry) do
      issue = Map.fetch!(entry, :issue)
      tracker_io(state, action, identifier, {:completed_refreshed, issue.id, Map.get(entry, :ref)}, :revalidate_completed, [issue])
    else
      finish_resume_control(action, identifier, Resume.do_resume_running_issue(state, entry))
    end
  end

  defp finish_resume_control(action, identifier, {reply, state}) do
    reply = if action == :resume_with_receipt, do: attach_resume_receipt(reply, state, identifier), else: reply
    StatusReport.notify_dashboard(state)
    {:reply, reply, state}
  end

  defp tracker_io(state, action, identifier, stage, function, args),
    do: {:reply, {:tracker_io, {action, identifier, stage}, function, args}, state}

  defp cleared_pause_issue(issue),
    do: issue |> RemoteControlMode.remove_issue_label(Resume.pause_override_label()) |> Map.put(:paused, false)

  defp tracker_refresh_error({:ok, []}, missing), do: missing
  defp tracker_refresh_error({:error, reason}, _missing), do: {:tracker_refresh_failed, reason}
  defp tracker_refresh_error(_result, _missing), do: {:tracker_refresh_failed, :invalid_tracker_issue}

  defp attach_resume_receipt({:ok, :resumed} = reply, state, issue_identifier) do
    with %{issue: %{id: issue_id}} <- State.find_running_by_identifier(state.running, issue_identifier),
         %{action: :resume, request_id: request_id} <- ControlLifecycle.current_pending(state.control_lifecycle, issue_id) do
      {:ok, {:resumed, request_id}}
    else
      _ -> reply
    end
  end

  defp attach_resume_receipt(reply, _state, _issue_identifier), do: reply

  @doc false
  @spec perform_tracker_io(term(), term()) :: term()
  def perform_tracker_io(:revalidate_completed, [issue]),
    do: Dispatcher.revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, DispatchPolicy.terminal_state_set())

  def perform_tracker_io(:update_issue_state, [id, state]), do: TicketTransition.write_state(id, state, writer: :pause_resume)
  def perform_tracker_io(:remove_label, [id, label]), do: TicketTransition.write_marker(id, :remove, label, writer: :pause_resume)
  def perform_tracker_io(:fetch_issue_states_by_ids, [ids]), do: Tracker.fetch_issue_states_by_ids(ids)
end
