defmodule Aiur.Orchestrator.Reconciler.Reactivation do
  @moduledoc false

  require Logger

  alias Aiur.Issue
  alias Aiur.Orchestrator.{CiLifecycle, Parking, PauseResume, State, TicketTransition}

  # A before_run hook failure parks the agent alive in
  # `AgentRunner.wait_for_before_run_resume/3`; resuming re-runs the hook inside
  # the agent's own loop WITHOUT going back through the dispatch counter, so a
  # persistently-failing hook (for example a real merge conflict) would retry on
  # every poll forever. Bound automatic recovery to a small number of attempts,
  # then leave the entry paused for operator-driven recovery.
  @max_before_run_resume_attempts 5

  @spec maybe_reactivate_or_refresh(State.t(), Issue.t()) :: State.t()
  def maybe_reactivate_or_refresh(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{control: %{status: :paused}, paused_reason: pause_reason} = running_entry
      when pause_reason not in [:before_run_failure, :ci_wait, :label_override] ->
        refresh_running_entry_issue(state, issue, running_entry)

      %{completed_provenance: true} = running_entry ->
        PauseResume.replace_completed_issue(state, running_entry, issue)

      %{control: %{status: :completed}} = running_entry ->
        PauseResume.replace_completed_issue(state, running_entry, issue)

      %{control: %{status: :deactivated}} = running_entry ->
        Parking.reconcile_deactivated(state, running_entry, issue, &refresh_running_entry_issue/3, &reactivate_deactivated_issue/3)

      %{control: %{status: :paused}, paused_reason: :before_run_failure} = running_entry ->
        resume_before_run_failure(state, running_entry, issue)

      %{control: %{status: :paused}, paused_reason: pause_reason} = running_entry
      when pause_reason in [:ci_wait, :label_override] ->
        resume_reactivated_issue(state, running_entry, issue, pause_reason)

      _ ->
        refresh_running_issue_state(state, issue)
    end
  end

  defp reactivate_deactivated_issue(state, running_entry, issue) do
    new_entry = Map.put(running_entry, :issue, issue)
    state = %{state | running: Map.put(state.running, issue.id, new_entry)}
    {_result, next_state} = TicketTransition.apply_effect(state, {:reactivate, new_entry})
    next_state
  end

  defp resume_reactivated_issue(state, running_entry, issue, pause_reason) do
    new_entry = Map.put(running_entry, :issue, issue)
    state = %{state | running: Map.put(state.running, issue.id, new_entry)}

    state =
      if pause_reason == :ci_wait,
        do: CiLifecycle.cancel_ci_wait_rewake(state, issue.id),
        else: state

    case TicketTransition.apply_effect(state, {:resume_paused, new_entry, false}) do
      {{:ok, :resumed}, next_state} ->
        next_state

      {{:error, reason}, next_state} ->
        Logger.info("Paused issue resume deferred: #{State.issue_context(issue)} reason=#{inspect(reason)}")

        next_state
    end
  end

  # Resume-to-live-pid: the parked agent is still alive and blocked awaiting the
  # `:resume_agent` signal, so `resume_paused_issue` unblocks it directly (no
  # re-dispatch). Because that bypasses the dispatch/thrash counter, we count the
  # attempts here and give up once the budget is spent so a persistent failure
  # cannot loop. Only a resume that actually fired (message delivered) burns
  # budget — a capacity deferral leaves it for the next poll.
  defp resume_before_run_failure(state, running_entry, issue) do
    attempts = Map.get(running_entry, :before_run_resume_attempts, 0)

    cond do
      attempts < @max_before_run_resume_attempts ->
        new_entry = Map.put(running_entry, :issue, issue)
        state = %{state | running: Map.put(state.running, issue.id, new_entry)}

        case TicketTransition.apply_effect(state, {:resume_paused, new_entry, false}) do
          {{:ok, :resumed}, next_state} ->
            bump_before_run_resume_attempts(next_state, issue.id)

          {{:error, reason}, next_state} ->
            Logger.info("before_run_failure resume deferred: #{State.issue_context(issue)} reason=#{inspect(reason)}")

            next_state
        end

      Map.get(running_entry, :before_run_resume_exhausted, false) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.warning(
          "orchestrator.before_run_resume_exhausted issue_id=#{issue.id} issue_identifier=#{Map.get(running_entry, :identifier)} attempts=#{attempts} leaving paused for operator recovery"
        )

        exhausted_entry = Map.put(running_entry, :before_run_resume_exhausted, true)
        state = %{state | running: Map.put(state.running, issue.id, exhausted_entry)}
        refresh_running_issue_state(state, issue)
    end
  end

  defp bump_before_run_resume_attempts(state, issue_id) do
    update_in(state.running, fn running ->
      case Map.get(running, issue_id) do
        %{} = entry ->
          current = Map.get(entry, :before_run_resume_attempts, 0)
          Map.put(running, issue_id, Map.put(entry, :before_run_resume_attempts, current + 1))

        _ ->
          running
      end
    end)
  end

  @spec refresh_running_issue_state(State.t(), Issue.t()) :: State.t()
  def refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  @spec refresh_running_entry_issue(State.t(), Issue.t(), map()) :: State.t()
  def refresh_running_entry_issue(%State{} = state, %Issue{} = issue, running_entry)
      when is_map(running_entry) do
    %{state | running: Map.put(state.running, issue.id, Map.put(running_entry, :issue, issue))}
  end
end
