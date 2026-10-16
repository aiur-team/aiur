defmodule Aiur.Orchestrator.CiLifecycle.ApprovedLandingFailureTest do
  use Aiur.TestSupport

  import Aiur.CiLifecycleTestSupport

  alias Aiur.Orchestrator.CiLifecycle

  setup :ci_lifecycle_setup

  test "an approved failure the batch shows not landing is held when GitHub shows auto-merge on" do
    {identifier, next} = poll_approved_failure("ci-approved-live-landing", %{"enabledAt" => "2026-10-16T07:54:08Z"})

    refute_received {:recorded, _, {:tracker_update, ^identifier, "rework", _}}
    assert_received :live_read
    refute_received {:recorded, _, {:resume_agent, _, _}}
    assert next.running[identifier].issue.state == "ci-wait"
  end

  test "an approved failure GitHub confirms is not landing still routes to rework" do
    {identifier, _next} = poll_approved_failure("ci-approved-not-landing", nil)

    assert_received {:recorded, _, {:tracker_update, ^identifier, "rework", _}}
  end

  defp poll_approved_failure(name, auto_merge_request) do
    identifier = unique_identifier(name)
    recorder = start_recorder()
    issue = %{issue(identifier, "ci-wait") | state_labels: ["ci-wait"]}

    state =
      issue
      |> running_state(recorder, :paused, paused_reason: :ci_wait)
      |> CiLifecycle.pause_issue_for_ci_wait(issue)

    parent = self()
    live_pr = %{"state" => "OPEN", "headRefOid" => "approved-head", "isDraft" => false, "reviewDecision" => "APPROVED", "autoMergeRequest" => auto_merge_request, "mergeQueueEntry" => nil}

    request_fun = fn request ->
      assert request[:body]["query"] =~ "autoMergeRequest"
      send(parent, :live_read)
      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequest" => live_pr}}}}}
    end

    result = %{
      decision: :failed,
      head_sha: "approved-head",
      pr_number: 944,
      failures: [%{name: "lint", result: "failure"}],
      review_decision: "APPROVED",
      auto_merge_request: nil,
      merge_queue_entry: nil
    }

    next = poll_ci(state, issue, result, token: "test-gh-token", request_fun: request_fun, ci_recovery_enabled: false)
    sync_recorder(recorder)
    {identifier, next}
  end
end
