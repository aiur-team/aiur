defmodule Aiur.Events.GithubCIPoller.RedHeadRoutingTest do
  use Aiur.TestSupport

  alias Aiur.CI.FailureDigest
  alias Aiur.Events.GithubCIPoller.{Evaluation, Recovery}
  alias Aiur.{Issue, JsonStore}
  alias Aiur.Orchestrator.CiLifecycle.FailureComment

  @run_url "https://github.com/owner/repo/actions/runs/99/job/1"

  setup do
    root = Aiur.TestSupport.tmp_root!("red_head_routing")
    File.mkdir_p!(root)
    path = Path.join(root, "recovery.json")
    parent = self()

    opts = [
      token: "test-gh-token",
      request_fun: github(1),
      ci_recovery_path: path,
      ci_recovery_enabled: true,
      alert_emitter: fn topic, _details ->
        send(parent, {:attention, topic})
        :ok
      end
    ]

    # The journal entry #4966 carried while its red `pr body` sat in ci-wait for hours.
    JsonStore.write!(path, %{
      "4966" => %{"pr" => 4968, "cycles" => 0, "heads" => %{}, "attentions" => ["rerun_skipped"], "hold" => %{"mode" => "hold", "reason" => "rerun_skipped", "sha" => "head", "tests" => ""}}
    })

    result = %{pr_number: 4968, head_sha: "head", decision: :failed, failures: [%{name: "pr body", url: @run_url}]}
    %{issue: %Issue{id: "4966", identifier: "4966"}, result: result, opts: opts}
  end

  test "a red pr body check is not masked by a hold recorded before the head went red", ctx do
    opts = Keyword.put(ctx.opts, :ci_failure_digest, fn _, _ -> {:ok, %FailureDigest{checks: [%{id: 1, name: "pr body", url: @run_url}]}} end)

    assert %{decision: :failed, failures: [%{name: "pr body"}]} = Recovery.recover(ctx.issue, ctx.result, opts)
    refute_received {:rerun, _}
  end

  test "a known flake under that hold gets one rerun, then routes when it fails again", ctx do
    digest = %FailureDigest{flake_only: true, checks: [%{id: 1, name: "test", url: @run_url}]}
    opts = Keyword.put(ctx.opts, :ci_failure_digest, fn _, _ -> {:ok, digest} end)
    result = %{ctx.result | failures: [%{name: "test"}]}

    assert %{decision: :pending, recovery: "rerun_requested"} = Recovery.recover(ctx.issue, result, opts)
    assert_received {:rerun, rerun_url}
    assert rerun_url =~ "/actions/runs/99/rerun-failed-jobs"

    rerun = %FailureDigest{digest | checks: [%{id: 2, name: "test", url: @run_url}]}
    opts = opts |> Keyword.put(:ci_failure_digest, fn _, _ -> {:ok, rerun} end) |> Keyword.put(:request_fun, github(2))

    assert %{decision: :failed} = Recovery.recover(ctx.issue, result, opts)
    refute_received {:rerun, _}
  end

  test "a red head whose rerun cannot start raises its attention once and still routes", ctx do
    opts = Keyword.put(ctx.opts, :ci_failure_digest, fn _, _ -> {:error, :digest_unavailable} end)
    issue = %Issue{id: "5051", identifier: "5051"}

    assert %{decision: :failed, recovery: nil} = Recovery.recover(issue, ctx.result, opts)
    assert_received {:attention, "ticket.5051.pr.ci_recovery.evidence_unavailable"}
    assert %{decision: :failed, recovery: nil} = Recovery.recover(issue, ctx.result, opts)
    refute_received {:attention, _}
  end

  test "a failed check run keeps its link for the rework comment" do
    checks = [%{"name" => "pr body", "status" => "completed", "conclusion" => "failure", "details_url" => @run_url}]
    assert %{decision: :failed, failures: [%{name: "pr body", url: @run_url}]} = Evaluation.evaluate(checks, %{"statuses" => []})
  end

  test "the rework comment names each failing check with its link" do
    body = FailureComment.body(%{pr_number: 4968, head_sha: "head", failures: [%{name: "pr body", url: @run_url}, %{name: "ci gate", url: nil}]})

    assert body =~ "PR #4968 head `head`"
    assert body =~ "- [pr body](#{@run_url})\n- ci gate"
  end

  # An open, ready PR whose Actions run 99 is on `attempt`; any other POST is a rerun request.
  defp github(attempt) do
    parent = self()

    fn
      %{method: :post, url: "https://api.github.com/graphql"} ->
        ok(%{"data" => %{"repository" => %{"pullRequest" => %{"state" => "OPEN", "headRefOid" => "head", "isDraft" => false, "reviewDecision" => nil, "mergeQueueEntry" => nil}}}})

      %{method: :post, url: url} ->
        send(parent, {:rerun, url})
        ok(%{})

      %{method: :get, url: url} ->
        assert String.ends_with?(url, "/actions/runs/99")
        ok(%{"head_sha" => "head", "run_attempt" => attempt, "status" => "completed", "conclusion" => "failure"})
    end
  end

  defp ok(body), do: {:ok, %{status: 200, body: body, headers: []}}
end
