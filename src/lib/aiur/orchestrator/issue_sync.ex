defmodule Aiur.Orchestrator.IssueSync do
  @moduledoc """
  Synchronizes polled issues into orchestrator state and derived events.
  Remote reconciliation work runs outside the orchestrator process.
  """

  alias Aiur.CurrentRunMembership
  alias Aiur.Issue
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.IssueSync.CapacityStarvation
  alias Aiur.Orchestrator.IssueSync.DecisionStoreOutage
  alias Aiur.Orchestrator.IssueSync.Dependencies
  alias Aiur.Orchestrator.IssueSync.FleetCapacity
  alias Aiur.Orchestrator.IssueSync.LabelHeal
  alias Aiur.Orchestrator.IssueSync.StrandedTickets
  alias Aiur.Orchestrator.IssueSync.TerminalVerification
  alias Aiur.Orchestrator.IssueSync.TransitionAlerts
  alias Aiur.Orchestrator.MembershipLifecycle
  alias Aiur.Orchestrator.OptimisticGuardEffects
  alias Aiur.Orchestrator.PushRouting
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusObservation
  alias Aiur.Orchestrator.TelemetryEvents
  alias Aiur.Orchestrator.TrackerTasks
  alias Aiur.Tracker
  alias Aiur.TrackerIdentity

  @spec sync_polled_issue_state(State.t(), list()) :: State.t()
  def sync_polled_issue_state(%State{} = state, issues) when is_list(issues) do
    sync_polled_issue_state(
      state,
      issues,
      &Tracker.fetch_issue_states_by_ids/1,
      &MembershipLifecycle.observe/2,
      DispatchPolicy.terminal_state_set(),
      &CurrentRunMembership.mark_reconciled/1
    )
  end

  def sync_polled_issue_state(%State{} = state, _issues), do: state

  @doc false
  @spec sync_polled_issue_state(
          State.t(),
          list(),
          ([String.t()] -> {:ok, [term()]} | {:error, term()}),
          (TrackerIdentity.t(), atom() -> term())
        ) :: State.t()
  def sync_polled_issue_state(%State{} = state, issues, fetch_issue_states_fun, observe_membership_fun)
      when is_list(issues) and is_function(fetch_issue_states_fun, 1) and is_function(observe_membership_fun, 2) do
    sync_polled_issue_state(
      state,
      issues,
      fetch_issue_states_fun,
      observe_membership_fun,
      DispatchPolicy.terminal_state_set()
    )
  end

  @doc false
  @spec sync_polled_issue_state(
          State.t(),
          list(),
          ([String.t()] -> {:ok, [term()]} | {:error, term()}),
          (TrackerIdentity.t(), atom() -> term()),
          MapSet.t()
        ) :: State.t()
  def sync_polled_issue_state(
        %State{} = state,
        issues,
        fetch_issue_states_fun,
        observe_membership_fun,
        terminal_states
      )
      when is_list(issues) and is_function(fetch_issue_states_fun, 1) and is_function(observe_membership_fun, 2) and
             is_struct(terminal_states, MapSet) do
    sync_polled_issue_state(
      state,
      issues,
      fetch_issue_states_fun,
      observe_membership_fun,
      terminal_states,
      &CurrentRunMembership.mark_reconciled/1,
      &CurrentRunMembership.set_terminal_verification_pending/2
    )
  end

  @doc false
  @spec sync_polled_issue_state(
          State.t(),
          list(),
          ([String.t()] -> {:ok, [term()]} | {:error, term()}),
          (TrackerIdentity.t(), atom() -> term()),
          MapSet.t(),
          (:fresh | :unavailable -> term())
        ) :: State.t()
  def sync_polled_issue_state(
        %State{} = state,
        issues,
        fetch_issue_states_fun,
        observe_membership_fun,
        terminal_states,
        mark_reconciled_fun
      )
      when is_list(issues) and is_function(fetch_issue_states_fun, 1) and is_function(observe_membership_fun, 2) and
             is_struct(terminal_states, MapSet) and is_function(mark_reconciled_fun, 1) do
    sync_polled_issue_state(
      state,
      issues,
      fetch_issue_states_fun,
      observe_membership_fun,
      terminal_states,
      mark_reconciled_fun,
      &CurrentRunMembership.set_terminal_verification_pending/2
    )
  end

  @doc false
  @spec sync_polled_issue_state(
          State.t(),
          list(),
          ([String.t()] -> {:ok, [term()]} | {:error, term()}),
          (TrackerIdentity.t(), atom() -> term()),
          MapSet.t(),
          (:fresh | :unavailable -> term()),
          (TrackerIdentity.t(), boolean() -> term())
        ) :: State.t()
  def sync_polled_issue_state(
        %State{} = state,
        issues,
        fetch_issue_states_fun,
        observe_membership_fun,
        terminal_states,
        mark_reconciled_fun,
        set_terminal_verification_pending_fun
      )
      when is_list(issues) and is_function(fetch_issue_states_fun, 1) and is_function(observe_membership_fun, 2) and
             is_struct(terminal_states, MapSet) and is_function(mark_reconciled_fun, 1) and
             is_function(set_terminal_verification_pending_fun, 2) do
    state = %{state | active_attention_topics: TransitionAlerts.active_attention_topics()}
    state = Reconciler.resolve_orphaned_divergence_attentions(state)
    previous_issues = state.last_polled_issues
    current_issues = Map.merge(Map.filter(previous_issues, fn {id, _issue} -> TrackerTasks.issue_pending?(state, id) end), issues_by_id(issues))

    {state, retained_issues} =
      TerminalVerification.record_disappearing_idle_terminals(
        state,
        previous_issues,
        current_issues,
        fetch_issue_states_fun,
        observe_membership_fun,
        terminal_states,
        mark_reconciled_fun,
        set_terminal_verification_pending_fun
      )

    state =
      Enum.reduce(issues, state, fn issue, state_acc ->
        previous_issue = Map.get(previous_issues, issue.id)

        state_acc
        |> TransitionAlerts.emit_task_state_transition_alert(previous_issue, issue)
        |> TransitionAlerts.emit_tracker_pause_transition_alert(previous_issue, issue)
        |> Dependencies.emit_dependency_transition_events(previous_issue, issue)
        |> TelemetryEvents.observe(previous_issue, issue)
        |> cancel_rework_ci(previous_issue, issue)
      end)

    state = PushRouting.recheck_cleared_dependency_pauses(state, fetch_issue_states_fun, issues)

    %{
      state
      | last_polled_issues: retained_issues,
        released_claims: purge_resolved_released_claims(state.released_claims, retained_issues, terminal_states)
    }
    |> StatusObservation.observe_tickets(issues, retained_issues)
    |> OptimisticGuardEffects.reconcile()
  end

  # The poll diff sees every writer's rework move (daemon or Executor label
  # edit), and fires once per entry, so a ticket parked in rework is not re-cancelled (#4814).
  defp cancel_rework_ci(state, %Issue{state: previous}, %Issue{state: current} = issue) do
    with "rework" <- DispatchPolicy.state_slug(current),
         false <- DispatchPolicy.state_slug(previous) == "rework",
         {module, function} <- Application.get_env(:aiur, :github_rework_ci_canceller) do
      apply(module, function, [issue.id])
    end

    state
  end

  defp cancel_rework_ci(state, _previous, _issue), do: state

  # A `released_claims` entry exists only to tell the operator that a claim was
  # dropped and still needs recovery. Once the ticket reaches a terminal tracker
  # state there is nothing left to recover, and the entry becomes a permanently
  # inflated `RELEASED CLAIMS n` that an operator will chase and find nothing
  # behind. Losing one line of history is cheap; a confident wrong count is not.
  #
  # Filter against the RETAINED issues, not the raw poll. A claim is released
  # because the tracker was failing or rate-limiting us, which is exactly when a
  # poll comes back partial — and a ticket merely absent from one such poll is
  # still pending terminal verification, not gone. `retained_issues` already
  # encodes that distinction, so an entry survives until the disappearance is
  # confirmed rather than vanishing on the first bad poll (#1475).
  defp purge_resolved_released_claims(released_claims, retained_issues, terminal_states) when is_map(released_claims) do
    Map.filter(released_claims, fn {issue_id, _release} ->
      case Map.get(retained_issues, issue_id) do
        %Issue{state: issue_state} -> not DispatchPolicy.terminal_issue_state?(issue_state, terminal_states)
        _confirmed_gone -> false
      end
    end)
  end

  defp issues_by_id(issues) do
    Enum.reduce(issues, %{}, fn
      %Issue{id: issue_id} = issue, acc when is_binary(issue_id) -> Map.put(acc, issue_id, issue)
      _issue, acc -> acc
    end)
  end

  @spec observe_human_review_handoffs(State.t(), list()) :: State.t()
  defdelegate observe_human_review_handoffs(arg0, arg1), to: TransitionAlerts

  @spec reconcile_contradictory_state_labels(State.t(), list()) :: {State.t(), list()}
  defdelegate reconcile_contradictory_state_labels(arg0, arg1), to: LabelHeal

  @spec reconcile_contradictory_state_labels(State.t(), list(), (String.t(), String.t() -> :ok | {:error, term()})) ::
          {State.t(), list()}
  defdelegate reconcile_contradictory_state_labels(arg0, arg1, arg2), to: LabelHeal

  @spec sync_stranded_ticket_reconciliation(State.t(), list()) :: State.t()
  defdelegate sync_stranded_ticket_reconciliation(arg0, arg1), to: StrandedTickets

  @spec sync_stranded_ticket_reconciliation(State.t(), list(), (String.t(), String.t() -> :ok | {:error, term()})) ::
          State.t()
  defdelegate sync_stranded_ticket_reconciliation(arg0, arg1, arg2), to: StrandedTickets

  @spec owned_or_scheduled?(State.t(), String.t()) :: boolean()
  defdelegate owned_or_scheduled?(arg0, arg1), to: StrandedTickets

  @spec blocker_map(term()) :: map()
  defdelegate blocker_map(arg0), to: Dependencies

  @spec enqueue_dependency_event(State.t(), Issue.t(), map(), atom()) :: State.t()
  defdelegate enqueue_dependency_event(arg0, arg1, arg2, arg3), to: Dependencies

  @spec sync_todo_capacity_alert(State.t(), list()) :: State.t()
  defdelegate sync_todo_capacity_alert(arg0, arg1), to: CapacityStarvation

  @spec sync_capacity_starvation_alert(State.t(), list(), integer()) :: State.t()
  defdelegate sync_capacity_starvation_alert(arg0, arg1, arg2), to: CapacityStarvation

  @spec sync_capacity_starvation_alert(State.t(), list()) :: State.t()
  defdelegate sync_capacity_starvation_alert(arg0, arg1), to: CapacityStarvation

  @spec sync_fleet_capacity_starved_alert(State.t(), list(), integer()) :: State.t()
  defdelegate sync_fleet_capacity_starved_alert(arg0, arg1, arg2), to: FleetCapacity

  @spec sync_fleet_capacity_starved_alert(State.t(), list()) :: State.t()
  defdelegate sync_fleet_capacity_starved_alert(arg0, arg1), to: FleetCapacity

  @spec sync_decision_store_unavailable_alert(State.t(), list()) :: State.t()
  defdelegate sync_decision_store_unavailable_alert(arg0, arg1), to: DecisionStoreOutage

  @spec sync_decision_store_unavailable_alert(State.t(), list(), integer()) :: State.t()
  defdelegate sync_decision_store_unavailable_alert(arg0, arg1, arg2), to: DecisionStoreOutage

  @spec sync_dependency_circular_wait_alert(State.t(), list(), integer()) :: State.t()
  defdelegate sync_dependency_circular_wait_alert(arg0, arg1, arg2), to: Dependencies

  @spec sync_dependency_circular_wait_alert(State.t(), list()) :: State.t()
  defdelegate sync_dependency_circular_wait_alert(arg0, arg1), to: Dependencies
end
