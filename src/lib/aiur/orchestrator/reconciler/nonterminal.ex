defmodule Aiur.Orchestrator.Reconciler.Nonterminal do
  @moduledoc false

  require Logger

  alias Aiur.{CurrentRunMembership, Issue, TrackerIdentity}
  alias Aiur.Orchestrator.{CiLifecycle, DispatchPolicy, HumanReview, LifecycleFence, MembershipLifecycle, PauseResume, State}
  alias Aiur.Orchestrator.Reconciler.{Divergence, Reactivation}

  @doc false
  @spec reconcile_terminal_issue_state(
          State.t(),
          Issue.t(),
          (TrackerIdentity.t(), atom() -> term()),
          (:fresh | :unavailable -> term())
        ) :: State.t() | {State.t(), [Aiur.Orchestrator.Effect.t()]}
  def reconcile_terminal_issue_state(state, issue, observe_membership_fun, mark_reconciled_fun) do
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
    if CurrentRunMembership.set_terminal_verification_pending(&CurrentRunMembership.set_terminal_verification_pending/2, issue.tracker_identity, false) in [:ok, :skipped] do
      {state, [{:terminate, issue.id, true}]}
    else
      mark_membership_unavailable(state, mark_reconciled_fun, issue.tracker_identity)
    end
  end

  @doc false
  @spec reconcile_nonterminal_issue_state(
          State.t(),
          Issue.t(),
          MapSet.t(),
          MapSet.t(),
          (TrackerIdentity.t(), atom() -> term())
        ) :: State.t() | {State.t(), [Aiur.Orchestrator.Effect.t()]}
  def reconcile_nonterminal_issue_state(
        state,
        issue,
        active_states,
        terminal_states,
        observe_membership_fun
      ) do
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

        state
        |> Divergence.clear_reported_divergence(issue.id)
        |> then(&{&1, [{:terminate, issue.id, false}]})

      !DispatchPolicy.issue_dispatch_authorized?(issue) and
          not DispatchPolicy.issue_dispatch_authorization_deferred?(issue) ->
        Logger.warning([
          "Issue dispatch authorization was revoked: ",
          State.issue_context(issue),
          "; stopping active agent"
        ])

        record_membership(issue, :replaced, observe_membership_fun)

        state
        |> Divergence.clear_reported_divergence(issue.id)
        |> then(&{&1, [{:terminate, issue.id, false}]})

      # Authorization could not be *checked* this cycle — a transient budget
      # hold, rate limit, or transport failure on the provenance fetch — as
      # opposed to verified revoked. Killing the agent here would convert a
      # 30-second throttle into a terminal `agent:error` via retry exhaustion,
      # so the running agent stays and the next poll re-verifies from a fresh
      # timeline once the cause clears (#2409).
      !DispatchPolicy.issue_dispatch_authorized?(issue) ->
        Logger.info([
          "Issue dispatch authorization is temporarily unverifiable (deferred); ",
          "keeping active agent: ",
          State.issue_context(issue)
        ])

        state

      # A ticket whose operator Command is open must not keep burning agent
      # turns re-verifying state while the next action is unchosen (#1637: 8
      # continuation turns on byte-identical state, then a fresh agent
      # cold-started). Stop the running agent deterministically instead of
      # relying on the agent's own cooperative `pause.request`, which silently
      # failed in that run. The dispatch gate then refuses to re-spawn it until
      # the Command is answered or dismissed.
      #
      # Deliberately fail-open: only a concrete `MapSet` membership stops the
      # agent. `nil` (set never computed) and `:unavailable` (decision store
      # read failed) leave healthy running agents alone — killing a running
      # fleet on a store outage would be worse than letting a blocked agent run
      # one more cycle. Fail-closed is the dispatch side's job.
      match?(%MapSet{}, state.blocked_ticket_ids) and
          MapSet.member?(state.blocked_ticket_ids, issue.id) ->
        Logger.info([
          "Issue has an open blocking Command: ",
          State.issue_context(issue),
          "; stopping active agent"
        ])

        record_membership(issue, :replaced, observe_membership_fun)

        state
        |> Divergence.clear_reported_divergence(issue.id)
        |> then(&{&1, [{:terminate, issue.id, false}]})

      Issue.paused?(issue) ->
        PauseResume.pause_issue_for_label_override(state, issue)

      true ->
        reconcile_routable_nonterminal_issue_state(
          state,
          issue,
          active_states,
          terminal_states,
          observe_membership_fun
        )
    end
  end

  defp reconcile_routable_nonterminal_issue_state(
         state,
         issue,
         active_states,
         terminal_states,
         observe_membership_fun
       ) do
    case LifecycleFence.reconcile_observed_state(state, issue, terminal_states) do
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
        Reactivation.maybe_reactivate_or_refresh(state, issue)

      CiLifecycle.ci_wait_state?(issue.state) ->
        {state, [{:pause_for_ci_wait, issue}]}

      HumanReview.human_review_state?(issue.state) ->
        {state, [{:maybe_deactivate_human_review, issue}]}

      DispatchPolicy.normalize_issue_state(issue.state) == "error" ->
        {state, [{:preserve_on_external_error, issue}]}

      true ->
        Logger.info([
          "Issue moved to non-active state: ",
          State.issue_context(issue),
          " state=",
          inspect(issue.state),
          "; stopping active agent"
        ])

        record_membership(issue, :replaced, observe_membership_fun)

        state
        |> Divergence.clear_reported_divergence(issue.id)
        |> then(&{&1, [{:terminate, issue.id, false}]})
    end
  end

  defp record_membership(%Issue{} = issue, lifecycle, observe_membership_fun) do
    MembershipLifecycle.record(issue, lifecycle, observe_membership_fun)
  end

  defp mark_membership_unavailable(state, mark_reconciled_fun, identity) do
    _ = CurrentRunMembership.set_terminal_verification_pending(&CurrentRunMembership.set_terminal_verification_pending/2, identity, true)
    _ = mark_reconciled_fun.(:unavailable)
    state
  rescue
    _error -> state
  catch
    _kind, _reason -> state
  end
end
