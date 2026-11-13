defmodule Aiur.Orchestrator.Reconciler.NonterminalDeferredTest do
  # Open-Games #310/#321/#322: a worker ended and its ticket left the active
  # states (ci-wait, error). Authorization only checks active states, so the
  # refreshed ticket stayed `:deferred` (missing trigger label), and the
  # reconciler kept the ended runner as if it were a live agent being
  # re-verified. The runner held its slot and `--todo` kept the claim, for
  # 35-60 minutes each time, until an operator stepped in.
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.Reconciler.Nonterminal
  alias Aiur.Orchestrator.State

  @active MapSet.new(["todo", "in-progress", "rework"])

  defp deferred(state_name) do
    %Issue{
      id: "issue-#{state_name}",
      identifier: "owner/repo##{state_name}",
      state: state_name,
      dispatch_authorized?: false,
      dispatch_authorization: :deferred
    }
  end

  defp reconcile(issue, status \\ :completed) do
    state = %State{running: %{issue.id => %{issue: issue, pid: nil, control: %{status: status}}}}
    {state, Nonterminal.reconcile_nonterminal_issue_state(state, issue, @active, MapSet.new(["done"]), fn _, _ -> :ok end)}
  end

  test "a ci-wait ticket whose authorization was never checked still gets its ci-wait handling" do
    issue = deferred("ci-wait")
    {state, result} = reconcile(issue)
    assert result == {state, [{:pause_for_ci_wait, issue}]}
  end

  test "an error ticket whose authorization was never checked still gets its error handling" do
    issue = deferred("error")
    {state, result} = reconcile(issue)
    assert result == {state, [{:preserve_on_external_error, issue}]}
  end

  # Open-Game-Maker #740: the run ended, then human review deactivated the
  # parked entry before CI moved the ticket on, so the ended runner no longer
  # read as completed.
  test "a ci-wait ticket whose ended runner human review deactivated still gets its ci-wait handling" do
    issue = deferred("ci-wait")
    {state, result} = reconcile(issue, :deactivated)
    assert result == {state, [{:pause_for_ci_wait, issue}]}
  end

  test "an active ticket whose authorization is deferred keeps its agent until the next poll re-verifies it" do
    issue = deferred("in-progress")
    {state, result} = reconcile(issue)
    assert result == state
  end
end
