defmodule Aiur.Events.GithubCIPoller.ReworkCancelledRerunTest do
  use Aiur.TestSupport

  alias Aiur.CI.FailureDigest
  alias Aiur.Events.GithubCIPoller.Recovery
  alias Aiur.GitHub.{CIRecoveryStore, ReworkCICancel}
  alias Aiur.Issue

  @run_url "https://github.com/aiur-team/aiur/actions/runs/99/job/1"
  @approved_pr %{
    "state" => "OPEN",
    "headRefOid" => "head",
    "isDraft" => false,
    "reviewDecision" => "APPROVED",
    "mergeQueueEntry" => nil,
    "autoMergeRequest" => %{"enabledAt" => "2026-11-06T00:00:00Z"}
  }

  setup do
    # `ReworkCICancel` reaches GitHub through `Access.parse_repo/0`, whose last
    # fallback is the checkout's `origin` remote. The time-bomb rerun copies src
    # to a directory outside any repository, so name the repo in the fixture
    # instead of inheriting it from git (#7562).
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "aiur-team/aiur")
    root = Aiur.TestSupport.tmp_root!("rework_cancelled_rerun")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    parent = self()

    opts = [
      token: "test-gh-token",
      request_fun: github(parent),
      ci_recovery_path: Path.join(root, "recovery.json"),
      ci_recovery_enabled: true,
      ci_recovery_now: 1000,
      ci_recovery_observation: {:ok, @approved_pr},
      ci_failure_digest: fn _, _ -> {:ok, %FailureDigest{checks: [%{id: 99, name: "ci gate", url: @run_url}]}} end,
      alert_emitter: fn topic, _details ->
        send(parent, {:alert, topic})
        :ok
      end
    ]

    %{issue: %Issue{id: "3864", identifier: "3864"}, opts: opts}
  end

  test "an approved head whose only CI was cancelled for rework is rerun exactly once", ctx do
    assert {:ok, [99]} = cancel_for_rework(ctx.opts)

    result = approved_cancelled_result()

    assert %{decision: :pending, recovery: "rerun_requested"} = Recovery.recover(ctx.issue, result, ctx.opts)
    assert reruns() == ["/repos/aiur-team/aiur/actions/runs/99/rerun-failed-jobs"]
    assert_received {:alert, "ticket.3864.pr.ci_recovery.rerun"}

    # The journaled attempt is the once-per-head bound: a second poll observes it.
    assert %{decision: :pending, recovery: "rerun_pending"} = Recovery.recover(ctx.issue, result, ctx.opts)
    assert reruns() == []
    refute_received {:alert, _}

    assert {:ok, %{"heads" => %{"head" => %{"runs" => [%{"id" => 99}]}}}} = CIRecoveryStore.read("3864", 42, ctx.opts)
  end

  test "an unapproved head keeps skipping its rework-cancelled run", ctx do
    assert {:ok, [99]} = cancel_for_rework(ctx.opts)

    assert %{decision: :pending, recovery: "rerun_skipped"} = Recovery.recover(ctx.issue, approved_cancelled_result(%{review_decision: nil}), ctx.opts)
    assert reruns() == []
    assert_received {:alert, "ticket.3864.pr.ci_recovery.rerun_skipped"}
  end

  test "an approved head whose cancelled run was not cancelled by Aiur keeps the approved-landing hold", ctx do
    assert %{decision: :pending, recovery: "approved_landing_pr"} = Recovery.recover(ctx.issue, approved_cancelled_result(), ctx.opts)
    assert reruns() == []
    refute_received {:alert, "ticket.3864.pr.ci_recovery.rerun"}
  end

  defp approved_cancelled_result(overrides \\ %{}) do
    Map.merge(%{pr_number: 42, head_sha: "head", decision: :pending, pending_reason: :ci_cancelled, failures: [], review_decision: "APPROVED"}, overrides)
  end

  # The daemon's rework path cancels the head's ci run and records it in the journal.
  defp cancel_for_rework(opts) do
    opts
    |> Keyword.put(:open_pr_fun, fn _ -> {:ok, %{"number" => 42, "head" => %{"sha" => "head"}}} end)
    |> Keyword.put(:cancel_fun, fn _id, _opts -> :ok end)
    |> then(&ReworkCICancel.cancel("3864", &1))
  end

  defp reruns do
    receive do
      {:rerun, path} -> [path | reruns()]
    after
      0 -> []
    end
  end

  # Run 99 is the head's cancelled ci run; its rerun POST is what recovery must send.
  defp github(parent) do
    fn
      %{method: :post, url: url} ->
        path = URI.parse(url).path
        send(parent, {:rerun, path})
        {:ok, %{status: 202, body: %{}, headers: []}}

      %{method: :get, url: url} ->
        if String.contains?(url, "/actions/runs?head_sha=") do
          ok(%{"workflow_runs" => [%{"id" => 99, "head_sha" => "head", "name" => "ci", "status" => "in_progress", "run_attempt" => 1}]})
        else
          ok(%{"id" => 99, "head_sha" => "head", "name" => "ci", "run_attempt" => 1, "status" => "completed", "conclusion" => "cancelled"})
        end
    end
  end

  defp ok(body), do: {:ok, %{status: 200, body: body, headers: []}}
end
