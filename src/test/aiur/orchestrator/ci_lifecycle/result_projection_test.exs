defmodule Aiur.Orchestrator.CiLifecycle.ResultProjectionTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.CiLifecycle.ResultProjection
  alias Aiur.Orchestrator.State

  test "the CI wait projection retains current-head check runs for Executor sweep" do
    issue = %Issue{id: "5847", identifier: "5847", state: "ci-wait"}
    checks = [%{"id" => 702, "name" => "pr body", "conclusion" => "success", "started_at" => "2026-10-22T18:10:00Z"}]

    state = ResultProjection.stash_last_ci_result(%State{}, issue, %{decision: :passed, head_sha: "head", pr_number: 5733, check_runs: checks})

    assert %{"5847" => %{check_runs: ^checks, head_sha: "head", tracker_state: "ci-wait"}} = state.ci_lifecycle.poll_cache
  end
end
