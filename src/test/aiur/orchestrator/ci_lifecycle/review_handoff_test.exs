defmodule Aiur.Orchestrator.CiLifecycle.ReviewHandoffTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.CiLifecycle.ReviewHandoff
  alias Aiur.Orchestrator.State

  test "a failed tracker write leaves the CI handoff state unchanged" do
    state = %State{}
    issue = %Issue{id: "ci-handoff-error", identifier: "CI-HANDOFF-ERROR", state: "ci-wait"}
    result = %{decision: :passed, pr_number: 45, head_sha: "ready-head"}

    assert ReviewHandoff.apply_transition(state, {:error, :stale_issue_state}, {issue, result}) == state
  end
end
