defmodule Aiur.Orchestrator.Reconciler do
  @moduledoc """
  Per-poll reconciliation of running entries against refreshed tracker states.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.{CurrentRunMembership, Issue, Tracker, TrackerIdentity}
  alias Aiur.Orchestrator

  alias Aiur.Orchestrator.{
    DispatchPolicy,
    LifecycleFence,
    MembershipLifecycle,
    PauseResume,
    RateLimitFallback,
    State
  }

  # A before_run hook failure parks the agent alive in
  # `AgentRunner.wait_for_before_run_resume/3`; resuming re-runs the hook inside
  # the agent's own loop WITHOUT going back through the dispatch counter, so a
  # persistently-failing hook (for example a real merge conflict) would retry on
  # every poll forever. Bound automatic recovery to a small number of attempts,
  # then leave the entry paused for operator-driven recovery.
  @max_before_run_resume_attempts 5

  @spec reconcile_running_lifecycle(State.t()) :: State.t()
  def reconcile_running_lifecycle(%State{} = state) do
    state = Orchestrator.reconcile_stalled_running_issues(state)
    state = Orchestrator.reconcile_overrunning_agents(state)
    state = Orchestrator.reconcile_pending_auto_resumes(state)
    RateLimitFallback.reconcile(state)
  end

  @spec refresh_running_issue_states(State.t()) :: State.t()
  def refresh_running_issue_states(%State{} = state) do
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            DispatchPolicy.active_state_set(),
            DispatchPolicy.terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @spec reconcile_running_issue_states([Issue.t()], State.t()) :: State.t()
  def reconcile_running_issue_states(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(
      issues,
      state,
      DispatchPolicy.active_state_set(),
      DispatchPolicy.terminal_state_set()
    )
  end

  @spec reconcile_running_issue_states([Issue.t()], State.t(), MapSet.t(), MapSet.t()) ::
          State.t()
  def reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  def reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  @spec reconcile_issue_state(Issue.t() | term(), State.t(), MapSet.t(), MapSet.t()) :: State.t()
  def reconcile_issue_state(issue, state, active_states, terminal_states) do
    reconcile_issue_state(
      issue,
      state,
      active_states,
      terminal_states,
      &MembershipLifecycle.observe/2,
      &CurrentRunMembership.mark_reconciled/1
    )
  end

  @doc false
  @spec reconcile_issue_state(
          Issue.t() | term(),
          State.t(),
          MapSet.t(),
          MapSet.t(),
          (TrackerIdentity.t(), atom() -> term())
        ) :: State.t()
  def reconcile_issue_state(
        %Issue{} = issue,
        state,
        active_states,
        terminal_states,
        observe_membership_fun
      )
      when is_function(observe_membership_fun, 2) do
    reconcile_issue_state(
      issue,
      state,
      active_states,
      terminal_states,
      observe_membership_fun,
      &CurrentRunMembership.mark_reconciled/1
    )
  end

  def reconcile_issue_state(
        _issue,
        state,
        _active_states,
        _terminal_states,
        _observe_membership_fun
      ),
      do: state

  @doc false
  @spec reconcile_issue_state(
          Issue.t() | term(),
          State.t(),
          MapSet.t(),
          MapSet.t(),
          (TrackerIdentity.t(), atom() -> term()),
          (:fresh | :unavailable -> term())
        ) :: State.t()
  def reconcile_issue_state(
        %Issue{} = issue,
        state,
        active_states,
        terminal_states,
        observe_membership_fun,
        mark_reconciled_fun
      )
      when is_function(observe_membership_fun, 2) and is_function(mark_reconciled_fun, 1) do
    if DispatchPolicy.terminal_issue_state?(issue.state, terminal_states) do
      case LifecycleFence.reconcile_observed_state(state, issue) do
        :admit ->
          reconcile_terminal_issue_state(
            state,
            issue,
            observe_membership_fun,
            mark_reconciled_fun
          )

        {:fenced, next_state} ->
          next_state
      end
    else
      reconcile_nonterminal_issue_state(state, issue, active_states, observe_membership_fun)
    end
  end

  def reconcile_issue_state(
        _issue,
        state,
        _active_states,
        _terminal_states,
        _observe_membership_fun,
        _mark_reconciled_fun
      ),
      do: state

  defp reconcile_terminal_issue_state(state, issue, observe_membership_fun, mark_reconciled_fun) do
    Logger.info([
      "Issue moved to terminal state: ",
      State.issue_context(issue),
      " state=",
      inspect(issue.state),
      "; stopping active agent"
    ])

    case record_membership(
           issue,
           MembershipLifecycle.terminal_lifecycle(issue.state),
           observe_membership_fun
         ) do
      :ok ->
        terminate_recorded_terminal_issue(state, issue, mark_reconciled_fun)

      {:error, :membership_observation_failed} ->
        mark_membership_unavailable(state, mark_reconciled_fun, issue.tracker_identity)
    end
  end

  defp terminate_recorded_terminal_issue(state, issue, mark_reconciled_fun) do
    if safely_set_terminal_verification_pending(issue.tracker_identity, false) == :ok do
      Orchestrator.terminate_running_issue(state, issue.id, true)
    else
      mark_membership_unavailable(state, mark_reconciled_fun, issue.tracker_identity)
    end
  end

  defp reconcile_nonterminal_issue_state(state, issue, active_states, observe_membership_fun) do
    cond do
      !DispatchPolicy.issue_routable_to_worker?(issue) ->
        Logger.info([
          "Issue no longer routed to this worker: ",
          State.issue_context(issue),
          " assignee=",
          inspect(issue.assignee_id),
          "; stopping active agent"
        ])

        record_membership(issue, :replaced, observe_membership_fun)
        Orchestrator.terminate_running_issue(state, issue.id, false)

      Issue.paused?(issue) ->
        PauseResume.pause_issue_for_label_override(state, issue)

      true ->
        reconcile_routable_nonterminal_issue_state(
          state,
          issue,
          active_states,
          observe_membership_fun
        )
    end
  end

  defp reconcile_routable_nonterminal_issue_state(
         state,
         issue,
         active_states,
         observe_membership_fun
       ) do
    case LifecycleFence.reconcile_observed_state(state, issue) do
      {:fenced, next_state} ->
        next_state

      :admit ->
        reconcile_unfenced_nonterminal_issue_state(
          state,
          issue,
          active_states,
          observe_membership_fun
        )
    end
  end

  defp reconcile_unfenced_nonterminal_issue_state(
         state,
         issue,
         active_states,
         observe_membership_fun
       ) do
    cond do
      DispatchPolicy.active_issue_state?(issue.state, active_states) ->
        maybe_reactivate_or_refresh(state, issue)

      Orchestrator.ci_wait_state?(issue.state) ->
        Orchestrator.pause_issue_for_ci_wait(state, issue)

      Orchestrator.human_review_state?(issue.state) ->
        Orchestrator.maybe_deactivate_human_review_issue(state, issue)

      Orchestrator.error_issue_state?(issue.state) ->
        Orchestrator.preserve_running_issue_on_external_error(state, issue)

      true ->
        Logger.info([
          "Issue moved to non-active state: ",
          State.issue_context(issue),
          " state=",
          inspect(issue.state),
          "; stopping active agent"
        ])

        record_membership(issue, :replaced, observe_membership_fun)
        Orchestrator.terminate_running_issue(state, issue.id, false)
    end
  end

  defp record_membership(%Issue{} = issue, lifecycle, observe_membership_fun) do
    MembershipLifecycle.record(issue, lifecycle, observe_membership_fun)
  end

  defp mark_membership_unavailable(state, mark_reconciled_fun, identity) do
    _ = safely_set_terminal_verification_pending(identity, true)
    _ = mark_reconciled_fun.(:unavailable)
    state
  rescue
    _error -> state
  catch
    _kind, _reason -> state
  end

  defp safely_set_terminal_verification_pending(identity, pending?) do
    if match?(%TrackerIdentity{}, identity) and TrackerIdentity.joinable?(identity) do
      case CurrentRunMembership.set_terminal_verification_pending(identity, pending?) do
        :ok -> :ok
        _ -> :error
      end
    else
      :ok
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  @spec maybe_reactivate_or_refresh(State.t(), Issue.t()) :: State.t()
  def maybe_reactivate_or_refresh(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{completed_provenance: true} = running_entry ->
        PauseResume.replace_completed_issue(state, running_entry, issue)

      %{control: %{status: :completed}} = running_entry ->
        PauseResume.replace_completed_issue(state, running_entry, issue)

      %{control: %{status: :deactivated}} = running_entry ->
        reactivate_deactivated_issue(state, running_entry, issue)

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
    {_result, next_state} = Orchestrator.reactivate_issue(state, new_entry)
    next_state
  end

  defp resume_reactivated_issue(state, running_entry, issue, pause_reason) do
    new_entry = Map.put(running_entry, :issue, issue)
    state = %{state | running: Map.put(state.running, issue.id, new_entry)}

    state =
      if pause_reason == :ci_wait,
        do: Orchestrator.cancel_ci_wait_rewake(state, issue.id),
        else: state

    case Orchestrator.resume_paused_issue(state, new_entry, false) do
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

        case Orchestrator.resume_paused_issue(state, new_entry, false) do
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

  @spec reconcile_missing_running_issue_ids(State.t(), [String.t()], [Issue.t() | term()]) ::
          State.t()
  def reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
      when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        Orchestrator.terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  def reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

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

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info([
          "Issue no longer visible during running-state refresh: issue_id=",
          issue_id,
          " issue_identifier=",
          inspect(identifier),
          "; stopping active agent"
        ])

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok
end
