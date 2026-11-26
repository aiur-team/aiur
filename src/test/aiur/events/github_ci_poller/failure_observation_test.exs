defmodule Aiur.Events.GithubCIPoller.FailureObservationTest do
  use Aiur.TestSupport

  alias Aiur.CI.FailureDigest
  alias Aiur.Events.GithubCIPoller.Recovery
  alias Aiur.GitHub.CIRecoveryStore
  alias Aiur.Issue

  setup do
    root = Aiur.TestSupport.tmp_root!("failure_observation")
    File.mkdir_p!(root)
    parent = self()

    issue = %Issue{id: "7091", identifier: "7091", state: "ci-wait", updated_at: DateTime.from_unix!(1)}

    failures = [
      failure(123_466_925_309, "coverage", "failure", "2026-10-29T16:00:00Z"),
      failure(123_466_929_416, "test", "failure", "2026-10-29T16:01:00Z")
    ]

    result = %{pr_number: 7089, head_sha: "a8d611f", base_sha: "base", decision: :failed, failures: failures}

    opts = [
      ci_recovery_path: Path.join(root, "recovery.json"),
      ci_recovery_enabled: true,
      main_watch_history: :disabled,
      alert_emitter: fn topic, details ->
        send(parent, {:attention, topic, details})
        :ok
      end,
      ci_failure_digest: fn head_sha, _opts ->
        send(parent, {:digest_built, head_sha})
        {:ok, %FailureDigest{checks: []}}
      end
    ]

    %{issue: issue, result: result, opts: opts}
  end

  test "recording identical evidence ignores issue timestamps and failure order", ctx do
    assert :ok = Recovery.record_failure(ctx.issue, ctx.result, ctx.opts)

    reordered = %{ctx.result | failures: Enum.reverse(ctx.result.failures)}
    later_issue = %{ctx.issue | updated_at: DateTime.from_unix!(2)}
    assert :ok = Recovery.record_failure(later_issue, reordered, ctx.opts)

    assert {:ok, %{"cycles" => 1, "last_cycle" => signature}} = CIRecoveryStore.read("7091", 7089, ctx.opts)
    assert String.starts_with?(signature, "ci-failure:v1:")
    refute_received {:attention, _, _}
  end

  test "a persisted handled observation wins over an older recovery hold", ctx do
    assert :ok = Recovery.record_failure(ctx.issue, ctx.result, ctx.opts)

    hold = %{"sha" => ctx.result.head_sha, "reason" => "loop", "tests" => "coverage, test", "mode" => "hold", "failed" => true}
    assert {:ok, _entry} = CIRecoveryStore.update("7091", 7089, &Map.put(&1, "hold", hold), ctx.opts)

    later_issue = %{ctx.issue | updated_at: DateTime.from_unix!(2)}
    assert %{decision: :pending, recovery: "handled_failure"} = Recovery.recover(later_issue, ctx.result, ctx.opts)
    refute_received {:digest_built, _}
  end

  test "new head, workflow attempt, or conclusion still routes", ctx do
    assert :ok = Recovery.record_failure(ctx.issue, ctx.result, ctx.opts)

    new_attempt = Map.update!(ctx.result, :failures, fn [failure | rest] -> [%{failure | id: failure.id + 1, completed_at: "2026-10-29T16:10:00Z"} | rest] end)
    new_conclusion = Map.update!(ctx.result, :failures, fn [failure | rest] -> [%{failure | result: "timed_out"} | rest] end)

    for changed <- [%{ctx.result | head_sha: "new-head"}, new_attempt, new_conclusion] do
      assert %{decision: :failed} = Recovery.recover(ctx.issue, changed, ctx.opts)
      assert_received {:digest_built, head_sha}
      assert head_sha == changed.head_sha
    end
  end

  test "three distinct handled observations retain the loop bound", ctx do
    for offset <- 0..2 do
      changed = Map.update!(ctx.result, :failures, fn [failure | rest] -> [%{failure | id: failure.id + offset} | rest] end)
      assert :ok = Recovery.record_failure(ctx.issue, changed, ctx.opts)
    end

    assert_received {:attention, "ticket.7091.pr.ci_recovery.loop", details}
    assert details[:message] =~ "3 failed CI/rework cycles"
    assert {:ok, %{"cycles" => 3}} = CIRecoveryStore.read("7091", 7089, ctx.opts)
  end

  defp failure(id, name, result, completed_at) do
    %{
      id: id,
      name: name,
      kind: "check_run",
      result: result,
      started_at: "2026-10-29T15:55:00Z",
      completed_at: completed_at,
      url: "https://github.com/aiur-team/aiur/actions/runs/40875210542/job/#{id}"
    }
  end
end
