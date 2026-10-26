defmodule Aiur.Orchestrator.CiLifecycle.RepoWideFailureTest do
  use Aiur.TestSupport

  import Aiur.CiLifecycleTestSupport

  alias Aiur.CI.FailureDigest
  alias Aiur.Events.GithubCIPoller.Recovery
  alias Aiur.Orchestrator.CiLifecycle

  setup :ci_lifecycle_setup

  test "an approved PR matching main's red signature stays in ci-wait without no-op rework" do
    identifier = unique_identifier("ci-repo-wide-red")
    recorder = start_recorder()
    issue = %{issue(identifier, "ci-wait") | state_labels: ["ci-wait"]}
    state = issue |> running_state(recorder, :paused, paused_reason: :ci_wait) |> CiLifecycle.pause_issue_for_ci_wait(issue)
    root = Aiur.TestSupport.tmp_root!("repo_wide_ci_recovery")
    parent = self()
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    digest = %FailureDigest{signature: "same-main-failure", checks: [%{name: "workflow security"}]}
    main = %{sha: "main-head", completed_at: 900, checks: [%{name: "workflow security", conclusion: "failure"}], digest: digest}

    next =
      poll_ci(
        state,
        issue,
        %{decision: :failed, head_sha: "approved-head", pr_number: 947, failures: [%{name: "workflow security", result: "failure"}], review_decision: "APPROVED"},
        ci_recovery: fn issue_arg, result, opts ->
          Recovery.recover(issue_arg, result, Keyword.merge(opts, ci_recovery_path: Path.join(root, "recovery.json"), main_watch_history: [main], ci_failure_digest: fn _, _ -> {:ok, digest} end))
        end,
        ci_recovery_observation: {:ok, %{"state" => "OPEN", "headRefOid" => "approved-head", "autoMergeRequest" => nil, "mergeQueueEntry" => nil}},
        alert_condition_state: fn _, _ -> :unknown end,
        alert_emitter: fn topic, _details ->
          send(parent, {:attention, topic})
          :ok
        end
      )

    sync_recorder(recorder)

    assert next.running[identifier].issue.state == "ci-wait"
    refute_received {:recorded, _, {:tracker_update, ^identifier, "rework", _}}
    refute_received {:recorded, _, {:resume_agent, _, _}}
    assert_received {:attention, topic}
    suffix = :crypto.hash(:sha256, digest.signature) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    assert topic == "system.main.ci.repo_wide_failure.#{suffix}"
    no_op_topic = "ticket.#{identifier}.agent.attention.no_op_rework"
    refute_received {:attention, ^no_op_topic}
  end
end
