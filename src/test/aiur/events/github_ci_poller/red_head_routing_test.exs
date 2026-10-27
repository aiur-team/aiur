defmodule Aiur.Events.GithubCIPoller.RedHeadRoutingTest do
  use Aiur.TestSupport

  alias Aiur.CI.FailureDigest
  alias Aiur.Events.GithubCIPoller.{Evaluation, Recovery}
  alias Aiur.Events.GithubWebhook.Deposit.Bodies
  alias Aiur.GitHub.{CIPollBatch, CIPollBatchTestSupport, ResourceStore}
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

  test "a known network failure in the Actions job log gets one per-head rerun", ctx do
    digest = %FailureDigest{checks: [%{id: 1, name: "checkout", url: @run_url}]}

    opts =
      ctx.opts
      |> Keyword.put(:ci_failure_digest, fn _, _ -> {:ok, digest} end)
      |> Keyword.put(:ci_job_log, fn 100, _ -> {:ok, "fatal: Failed to connect to github.com port 443"} end)
      |> Keyword.put(:request_fun, github(1))

    assert %{decision: :pending, recovery: "rerun_requested"} = Recovery.recover(ctx.issue, ctx.result, opts)
    assert_received {:rerun, rerun_url}
    assert rerun_url =~ "/actions/runs/99/rerun-failed-jobs"

    refute_received {:rerun, _}
    assert %{decision: :pending, recovery: "rerun_pending"} = Recovery.recover(ctx.issue, ctx.result, opts)
    refute_received {:rerun, _}
  end

  test "a network-looking log with an ExUnit failure is not rerun", ctx do
    digest = %FailureDigest{checks: [%{id: 1, name: "test", url: @run_url}]}

    opts =
      ctx.opts
      |> Keyword.put(:ci_failure_digest, fn _, _ -> {:ok, digest} end)
      |> Keyword.put(:ci_job_log, fn 100, _ -> {:ok, "Failed to connect to github.com\nExUnit: assertion failed"} end)

    assert %{decision: :failed} = Recovery.recover(ctx.issue, ctx.result, opts)
    refute_received {:rerun, _}
  end

  test "a failed run containing a network and an ordinary failed job is not rerun", ctx do
    digest = %FailureDigest{checks: [%{id: 1, name: "checkout", url: @run_url}]}

    opts =
      ctx.opts
      |> Keyword.put(:ci_failure_digest, fn _, _ -> {:ok, digest} end)
      |> Keyword.put(:ci_job_log, fn id, _ ->
        send(self(), {:job_log, id})
        if id == 100, do: {:ok, "Failed to connect to github.com"}, else: {:ok, "Assertion with == failed"}
      end)
      |> Keyword.put(:request_fun, github(1, [%{"id" => 100, "conclusion" => "failure"}, %{"id" => 101, "conclusion" => "failure"}]))

    assert %{decision: :failed} = Recovery.recover(ctx.issue, ctx.result, opts)
    assert_received {:job_log, 100}
    assert_received {:job_log, 101}
    refute_received {:rerun, _}
  end

  test "a red head whose rerun cannot start raises its attention once, retries after ten minutes, then routes", ctx do
    opts = Keyword.put(ctx.opts, :ci_failure_digest, fn _, _ -> {:error, :digest_unavailable} end)
    issue = %Issue{id: "5051", identifier: "5051"}

    assert %{decision: :pending, recovery: "evidence_unavailable"} = Recovery.recover(issue, ctx.result, Keyword.put(opts, :ci_recovery_now, 1000))
    assert_received {:attention, "ticket.5051.pr.ci_recovery.evidence_unavailable"}
    assert %{decision: :failed, recovery: nil} = Recovery.recover(issue, ctx.result, Keyword.put(opts, :ci_recovery_now, 1600))
    assert %{decision: :failed, recovery: nil} = Recovery.recover(issue, ctx.result, Keyword.put(opts, :ci_recovery_now, 1700))
    refute_received {:attention, _}
  end

  test "a failed check run keeps its link for the rework comment" do
    checks = [%{"name" => "pr body", "status" => "completed", "conclusion" => "failure", "details_url" => @run_url}]
    assert %{decision: :failed, failures: [%{name: "pr body", url: @run_url}]} = Evaluation.evaluate(checks, %{"statuses" => []})
  end

  test "a polled red check run and status keep their links into the rework comment" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    ResourceStore.reset()
    on_exit(&ResourceStore.reset/0)
    status_url = "https://ci.example/legacy/1"

    node =
      update_in(CIPollBatchTestSupport.pull_request(), ["commits", "nodes", Access.at(0), "commit", "statusCheckRollup", "contexts", "nodes"], fn [run, status] ->
        [Map.merge(run, %{"conclusion" => "FAILURE", "detailsUrl" => @run_url}), Map.merge(status, %{"state" => "FAILURE", "targetUrl" => status_url})]
      end)

    request_fun = fn %{method: :post} -> CIPollBatchTestSupport.ci_response(Map.put(node, "baseRefOid", "base-77")) end
    assert {:ok, %{"42" => batch}} = CIPollBatch.fetch(["42"], token: "test-gh-token", request_fun: request_fun, branch_names_by_target: %{"42" => "aiur/42-ci-batch"})
    assert batch.pull_request["base"]["sha"] == "base-77"

    %{failures: failures} = Evaluation.evaluate(batch.check_runs, batch.commit_status)
    assert FailureComment.body(%{pr_number: 77, head_sha: "head-77", failures: failures}) =~ "- [test](#{@run_url})\n- [legacy](#{status_url})"
  end

  test "a webhook check_run delivery keeps its link into the evaluation" do
    check_run = %{
      "id" => 7,
      "name" => "pr body",
      "status" => "completed",
      "conclusion" => "failure",
      "head_sha" => "head",
      "details_url" => @run_url,
      "pull_requests" => [%{"head" => %{"ref" => "aiur/4966-x"}}]
    }

    assert [{:merge_check_run, "4966", "head", normalized}] = Bodies.bodies("check_run", %{"check_run" => check_run}, [])
    assert %{failures: [%{name: "pr body", url: @run_url}]} = Evaluation.evaluate([normalized], %{"statuses" => []})
  end

  test "the rework comment names each failing check with its link" do
    body = FailureComment.body(%{pr_number: 4968, head_sha: "head", failures: [%{name: "pr body", url: @run_url}, %{name: "ci gate", url: nil}]})

    assert body =~ "PR #4968 head `head`"
    assert body =~ "- [pr body](#{@run_url})\n- ci gate"
  end

  # An open, ready PR whose Actions run 99 is on `attempt`; any other POST is a rerun request.
  defp github(attempt, jobs \\ [%{"id" => 100, "conclusion" => "failure"}]) do
    parent = self()

    fn
      %{method: :post, url: "https://api.github.com/graphql"} ->
        ok(%{"data" => %{"repository" => %{"pullRequest" => %{"state" => "OPEN", "headRefOid" => "head", "isDraft" => false, "reviewDecision" => nil, "mergeQueueEntry" => nil}}}})

      %{method: :post, url: url} ->
        send(parent, {:rerun, url})
        ok(%{})

      %{method: :get, url: url} when is_binary(url) ->
        cond do
          String.contains?(url, "/actions/runs?head_sha=") ->
            ok(%{"workflow_runs" => [%{"id" => 99, "name" => "CI", "head_sha" => "head", "run_attempt" => attempt}]})

          String.ends_with?(url, "/actions/runs/99/jobs?per_page=100") ->
            ok(%{"jobs" => jobs})

          String.ends_with?(url, "/actions/jobs/100/logs") ->
            ok("ordinary failure")

          String.ends_with?(url, "/actions/runs/99") ->
            ok(%{"head_sha" => "head", "run_attempt" => attempt, "name" => "CI", "status" => "completed", "conclusion" => "failure"})

          true ->
            flunk("unexpected GET #{url}")
        end
    end
  end

  defp ok(body), do: {:ok, %{status: 200, body: body, headers: []}}
end
