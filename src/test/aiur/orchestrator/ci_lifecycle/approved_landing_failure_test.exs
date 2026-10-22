defmodule Aiur.Orchestrator.CiLifecycle.ApprovedLandingFailureTest do
  use Aiur.TestSupport

  import Aiur.CiLifecycleTestSupport

  alias Aiur.Events.GithubCIPoller.Recovery
  alias Aiur.Orchestrator.CiLifecycle

  setup :ci_lifecycle_setup

  test "PR-caused failures withdraw an approved landing and hand off the job names to rework" do
    identifier = unique_identifier("ci-approved-pr-caused")
    topic = "ticket.#{identifier}.ci.failed"
    test_pid = self()
    recovery_path = Aiur.TestSupport.tmp_root!("approved_ci_recovery") <> ".json"
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(recovery_path) end)
    recorder = start_recorder(topic)
    issue = %{issue(identifier, "ci-wait") | state_labels: ["ci-wait"]}
    state = issue |> running_state(recorder, :paused, paused_reason: :ci_wait) |> CiLifecycle.pause_issue_for_ci_wait(issue)

    next =
      poll_ci(
        state,
        issue,
        %{
          decision: :failed,
          head_sha: "approved-head",
          base_sha: "base-head",
          pr_number: 944,
          failures: [%{name: "browser spec", result: "failure"}],
          review_decision: "APPROVED",
          auto_merge_request: %{"enabledAt" => "now"},
          merge_queue_entry: nil
        },
        ci_recovery: fn target_issue, result, _poll_opts ->
          Recovery.recover(target_issue, result,
            ci_recovery_path: recovery_path,
            ci_recovery_enabled: true,
            main_watch_history: [%{sha: "base-head", checks: [%{name: "browser spec", conclusion: "success"}]}],
            ci_recovery_observation:
              {:ok, %{"state" => "OPEN", "headRefOid" => "approved-head", "reviewDecision" => "APPROVED", "autoMergeRequest" => %{"enabledAt" => "now"}, "mergeQueueEntry" => nil}},
            withdraw_landing: fn 944 -> {:ok, [:auto_merge_disabled]} end
          )
        end,
        ci_failure_commenter: fn _target, comment ->
          send(test_pid, {:failure_comment, comment})
          :ok
        end
      )

    sync_recorder(recorder)

    assert_received {:recorded, 1, {:tracker_update, ^identifier, "rework", [expected_state: "ci-wait"]}}
    assert_received {:recorded, 2, {:event, %{topic: ^topic}}}
    assert_received {:recorded, 3, {:agent_queue_updated, ^identifier, 1, false}}
    assert_received {:failure_comment, comment}
    assert comment =~ "browser spec (new failure on PR head)"
    assert next.running[identifier].issue.state == "rework"
    assert is_integer(next.ci_lifecycle.ci_observed_at_ms[identifier])
    assert File.exists?(recovery_path)
  end

  test "inherited failures on an approved landing remain in ci-wait" do
    identifier = unique_identifier("ci-approved-inherited")
    recorder = start_recorder()
    recovery_path = Aiur.TestSupport.tmp_root!("inherited_ci_recovery") <> ".json"
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(recovery_path) end)
    issue = %{issue(identifier, "ci-wait") | state_labels: ["ci-wait"]}
    state = issue |> running_state(recorder, :paused, paused_reason: :ci_wait) |> CiLifecycle.pause_issue_for_ci_wait(issue)

    next =
      poll_ci(
        state,
        issue,
        %{
          decision: :failed,
          head_sha: "approved-head",
          base_sha: "base-head",
          pr_number: 945,
          failures: [%{name: "browser spec", result: "failure"}],
          review_decision: "APPROVED",
          auto_merge_request: nil,
          merge_queue_entry: nil
        },
        ci_recovery: fn target_issue, result, _poll_opts ->
          Recovery.recover(target_issue, result,
            ci_recovery_path: recovery_path,
            ci_recovery_enabled: true,
            main_watch_history: [%{sha: "base-head", checks: [%{name: "browser spec", conclusion: "failure"}]}],
            ci_recovery_observation:
              {:ok, %{"state" => "OPEN", "headRefOid" => "approved-head", "reviewDecision" => "APPROVED", "autoMergeRequest" => %{"enabledAt" => "now"}, "mergeQueueEntry" => nil}},
            withdraw_landing: fn _ -> flunk("inherited failures must not withdraw an approved landing") end
          )
        end
      )

    refute_received {:recorded, _, {:tracker_update, ^identifier, "rework", _}}
    assert next.running[identifier].issue.state == "ci-wait"
  end
end
