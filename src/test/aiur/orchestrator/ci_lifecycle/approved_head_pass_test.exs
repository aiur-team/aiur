defmodule Aiur.Orchestrator.CiLifecycle.ApprovedHeadPassTest do
  use Aiur.TestSupport

  import Aiur.CiLifecycleTestSupport

  setup :ci_lifecycle_setup

  test "a reviewed ci-wait head follows the existing approved path" do
    identifier = unique_identifier("ci-ready-approved")
    recorder = start_recorder()
    issue = issue(identifier, "ci-wait")
    state = running_state(issue, recorder, :paused, paused_reason: :ci_wait)

    next = poll_ci(state, issue, %{decision: :passed, head_sha: "approved-head", pr_number: 943, draft?: false, review_decision: "APPROVED", reviewed_head?: true})

    sync_recorder(recorder)
    assert_received {:recorded, _position, {:tracker_update, ^identifier, "in-progress", [expected_state: "ci-wait"]}}
    refute_received {:recorded, _position, {:tracker_update, ^identifier, "human-review", _opts}}
    assert next.running[identifier].issue.state == "in-progress"
  end
end
