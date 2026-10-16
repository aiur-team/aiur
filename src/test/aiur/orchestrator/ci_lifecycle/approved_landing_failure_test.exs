defmodule Aiur.Orchestrator.CiLifecycle.ApprovedLandingFailureTest do
  use Aiur.TestSupport

  import Aiur.CiLifecycleTestSupport

  alias Aiur.Orchestrator.CiLifecycle

  setup :ci_lifecycle_setup

  test "approved CI failure with unknown batch landing state refreshes GitHub before rework" do
    identifier = unique_identifier("ci-approved-unknown-landing")
    recorder = start_recorder()
    issue = %{issue(identifier, "ci-wait") | state_labels: ["ci-wait"]}

    state =
      issue
      |> running_state(recorder, :paused, paused_reason: :ci_wait)
      |> CiLifecycle.pause_issue_for_ci_wait(issue)

    refreshed_request = fn request ->
      query = request[:body]["query"]
      assert query =~ "autoMergeRequest"
      assert query =~ "mergeQueueEntry"

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "pullRequest" => %{
                 "state" => "OPEN",
                 "headRefOid" => "approved-head",
                 "isDraft" => false,
                 "reviewDecision" => "APPROVED",
                 "autoMergeRequest" => %{"enabledAt" => "2026-10-16T07:54:08Z"},
                 "mergeQueueEntry" => nil
               }
             }
           }
         }
       }}
    end

    next =
      poll_ci(
        state,
        issue,
        %{
          decision: :failed,
          head_sha: "approved-head",
          pr_number: 944,
          failures: [%{name: "lint", result: "failure"}],
          review_decision: "APPROVED",
          auto_merge_request: nil,
          merge_queue_entry: nil
        },
        request_fun: refreshed_request
      )

    sync_recorder(recorder)
    refute_received {:recorded, _, {:tracker_update, ^identifier, "rework", _}}
    refute_received {:recorded, _, {:resume_agent, _, _}}
    assert next.running[identifier].issue.state == "ci-wait"
  end
end
