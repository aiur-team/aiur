defmodule Aiur.Orchestrator.CiLifecycle.EarlyFailureTest do
  # A ticket parked in ci-wait gets no turn until CI decides. A required check
  # that already failed decides it: waiting for the slower jobs on the same
  # head left the worker idle while the Executor reworked it by hand.
  use Aiur.TestSupport

  import Aiur.CiLifecycleTestSupport

  alias Aiur.CI.FailureDigest
  alias Aiur.Events.GithubCIPoller.Recovery
  alias Aiur.Orchestrator.CiLifecycle

  setup :ci_lifecycle_setup

  @error "packages/gm-cli/test/gm-core.test.ts: skills/gm-core/SKILL.md has 122 lines; the cap is 120"

  defp early_failure(pr_number) do
    %{
      decision: :failed,
      checks_incomplete: true,
      head_sha: "red-head",
      base_sha: "base-head",
      pr_number: pr_number,
      failures: [%{name: "workspace", kind: "check_run", result: "failure", url: "https://github.test/runs/1/job/2", excerpt: nil}]
    }
  end

  defp digest(check_overrides) do
    check = Map.merge(%{id: nil, name: "workspace", url: nil, tests: [], truncated: false, flake_only: false, test_only: false, errors: [@error, "Process exit"]}, check_overrides)
    %FailureDigest{checks: [check], flake_only: check.flake_only}
  end

  defp recover_with(recovery_path, digest) do
    fn target_issue, result, _poll_opts ->
      Recovery.recover(target_issue, result,
        ci_recovery_path: recovery_path,
        ci_recovery_enabled: true,
        ci_failure_digest: fn _, _ -> {:ok, digest} end,
        main_watch_history: [%{sha: "base-head", checks: [%{name: "workspace", conclusion: "success"}]}],
        ci_recovery_observation: {:ok, %{"state" => "OPEN", "headRefOid" => "red-head", "isDraft" => false, "mergeQueueEntry" => nil}}
      )
    end
  end

  defp recovery_path(name) do
    path = Aiur.TestSupport.tmp_root!(name) <> ".json"
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    path
  end

  test "a ci-wait ticket moves to rework on a failed required check while other checks still run, quoting the first error lines" do
    identifier = unique_identifier("ci-early-failure")
    topic = "ticket.#{identifier}.ci.failed"
    test_pid = self()
    recorder = start_recorder(topic)
    issue = %{issue(identifier, "ci-wait") | state_labels: ["ci-wait"]}
    state = issue |> running_state(recorder, :paused, paused_reason: :ci_wait) |> CiLifecycle.pause_issue_for_ci_wait(issue)

    next =
      poll_ci(state, issue, early_failure(832),
        ci_recovery: recover_with(recovery_path("early_ci_recovery"), digest(%{})),
        ci_failure_commenter: fn _target, comment ->
          send(test_pid, {:failure_comment, comment})
          :ok
        end
      )

    sync_recorder(recorder)

    assert_received {:recorded, 1, {:tracker_update, ^identifier, "rework", [expected_state: "ci-wait"]}}
    assert_received {:recorded, _, {:event, %{topic: ^topic, message: message}}}
    assert message =~ "CI failed: workspace"
    assert message =~ @error
    assert_received {:failure_comment, comment}
    assert comment =~ "- [workspace](https://github.test/runs/1/job/2)\n  > " <> @error
    assert next.running[identifier].issue.state == "rework"
  end

  test "an early failure the recovery would rerun as a flake waits for the run to finish" do
    identifier = unique_identifier("ci-early-flake")
    recorder = start_recorder()
    issue = %{issue(identifier, "ci-wait") | state_labels: ["ci-wait"]}
    state = issue |> running_state(recorder, :paused, paused_reason: :ci_wait) |> CiLifecycle.pause_issue_for_ci_wait(issue)

    next = poll_ci(state, issue, early_failure(833), ci_recovery: recover_with(recovery_path("early_ci_flake"), digest(%{flake_only: true})))

    refute_received {:recorded, _, {:tracker_update, ^identifier, "rework", _}}
    assert next.running[identifier].issue.state == "ci-wait"
    # A rerun request against a run still in progress fails into an attention hold.
    assert %{decision: :pending, pending_reason: :check_runs_incomplete} = cached = next.ci_lifecycle.poll_cache[identifier]
    assert cached[:recovery] == nil
  end

  # Review reads a failed verdict as a replay of the reviewed head and records
  # that head; a partial run must not get that far, so review sees running CI.
  test "a ticket in review treats an early failure as CI still running" do
    identifier = unique_identifier("ci-early-review")
    recorder = start_recorder()
    issue = %{issue(identifier, "human-review") | state_labels: ["human-review"]}
    state = running_state(issue, recorder, :paused, [])

    next = poll_ci(state, issue, early_failure(834))

    assert_received {:recorded, _, {:tracker_update, ^identifier, "ci-wait", _}}
    refute_received {:recorded, _, {:tracker_update, ^identifier, "rework", _}}
    refute Map.has_key?(next.ci_lifecycle.approved_heads, identifier)
  end
end
