defmodule Aiur.Orchestrator.CiLifecycle.ExternalCi do
  @moduledoc """
  CI poll handling under `merge_policy.ci: external` (#8098).

  An outside gate decides merge readiness, so GitHub check results (red, absent
  or pending) never move the ticket or wake its agent. Only a confirmed merge
  conflict, which is real new input, still routes to rework. A ticket left in
  `ci-wait` moves to `human-review` once its PR is ready, because no check run
  will ever release it.
  """

  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.CiLifecycle.ApprovedHeadConflict
  alias Aiur.Orchestrator.CiLifecycle.Outcome.Apply
  alias Aiur.Orchestrator.CiLifecycle.ReviewHandoff
  alias Aiur.Orchestrator.CiLifecycle.Transition
  alias Aiur.Orchestrator.HumanReview
  alias Aiur.Orchestrator.State

  @spec apply_poll_result(State.t(), Aiur.Issue.t(), map(), keyword()) :: State.t()
  def apply_poll_result(state, issue, result, opts) do
    ticket_state = Transition.effective_ci_state(issue)
    ci_wait? = CiLifecycle.ci_wait_state?(ticket_state)

    cond do
      (ci_wait? or HumanReview.human_review_state?(ticket_state)) and confirmed_conflict?(result) ->
        Apply.route_conflicting_pr(state, issue, result, opts)

      ci_wait? and ready_pr?(result) ->
        ReviewHandoff.transition(state, issue, result)

      true ->
        state
    end
  end

  defp confirmed_conflict?(result) do
    result[:mergeable] == "CONFLICTING" and result[:conflict_confirmed?] == true and not ApprovedHeadConflict.primary_owns?(result)
  end

  defp ready_pr?(result), do: result[:draft?] == false and is_integer(result[:pr_number]) and is_binary(result[:head_sha])
end
