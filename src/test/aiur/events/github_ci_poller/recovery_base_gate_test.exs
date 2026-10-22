defmodule Aiur.Events.GithubCIPoller.RecoveryBaseGateTest do
  use Aiur.TestSupport

  alias Aiur.CI.FailureDigest
  alias Aiur.Events.GithubCIPoller.Recovery
  alias Aiur.GitHub.CIRecoveryStore
  alias Aiur.Issue

  @run_url "https://github.com/owner/repo/actions/runs/99/job/1"

  setup do
    root = Aiur.TestSupport.tmp_root!("recovery_base_gate")
    File.mkdir_p!(root)
    parent = self()

    opts = [
      token: "test-gh-token",
      request_fun: github(202),
      ci_recovery_path: Path.join(root, "recovery.json"),
      ci_recovery_enabled: true,
      ci_recovery_now: 1000,
      ci_failure_digest: fn _, _ -> {:ok, %FailureDigest{checks: [%{id: 1, name: "test", url: @run_url}]}} end,
      alert_emitter: fn topic, _details ->
        send(parent, {:attention, topic})
        :ok
      end
    ]

    result = %{pr_number: 42, head_sha: "head", base_sha: "base", decision: :failed, failures: [%{name: "test", url: @run_url}]}
    %{issue: %Issue{id: "3864", identifier: "3864"}, result: result, opts: opts}
  end

  test "a check red on the head that passed on the base routes", ctx do
    opts = Keyword.put(ctx.opts, :main_watch_history, [base("success")])
    assert %{decision: :failed} = routed = Recovery.recover(ctx.issue, ctx.result, opts)
    refute routed[:recovery]
    refute_received {:attention, _}
  end

  test "a PR-only check absent from the base routes", ctx do
    opts = Keyword.put(ctx.opts, :main_watch_history, [%{sha: "base", checks: [%{name: "build", conclusion: "success"}]}])
    assert %{decision: :failed} = routed = Recovery.recover(ctx.issue, ctx.result, opts)
    refute routed[:recovery]
  end

  test "a check red on both head and base holds with one attention until the base passes", ctx do
    opts = Keyword.put(ctx.opts, :main_watch_history, [base("failure")])
    assert %{decision: :pending, recovery: "base_inherited"} = Recovery.recover(ctx.issue, ctx.result, opts)
    assert_received {:attention, "ticket.3864.pr.ci_recovery.base_inherited"}
    assert %{decision: :pending, recovery: "base_inherited"} = Recovery.recover(ctx.issue, ctx.result, opts)
    refute_received {:attention, _}

    opts = Keyword.put(opts, :main_watch_history, [base("success")])
    assert %{decision: :failed, recovery: nil} = Recovery.recover(ctx.issue, ctx.result, opts)
  end

  test "a base commit with no recorded result holds as unknown for one main CI run, then routes", ctx do
    opts = Keyword.put(ctx.opts, :main_watch_history, [%{base("success") | sha: "older"}])
    assert %{decision: :pending, recovery: "base_unknown"} = Recovery.recover(ctx.issue, ctx.result, opts)
    assert_received {:attention, "ticket.3864.pr.ci_recovery.base_unknown"}
    assert %{decision: :pending, recovery: "base_unknown"} = Recovery.recover(ctx.issue, ctx.result, Keyword.put(opts, :ci_recovery_now, 4599))

    assert %{decision: :failed} = routed = Recovery.recover(ctx.issue, ctx.result, Keyword.put(opts, :ci_recovery_now, 4600))
    refute routed[:recovery]
    refute_received {:attention, _}
  end

  test "a PR-only check routes even when the base commit was never recorded", ctx do
    opts = Keyword.put(ctx.opts, :main_watch_history, [%{base("success") | sha: "older"}])
    result = %{ctx.result | failures: [%{name: "pr body", url: @run_url}]}
    assert %{decision: :failed} = routed = Recovery.recover(ctx.issue, result, opts)
    refute routed[:recovery]
  end

  test "a worker error on a check red on both head and base holds", ctx do
    opts = Keyword.put(ctx.opts, :main_watch_history, [base("failure")])
    assert %{decision: :pending, recovery: "base_inherited"} = Recovery.complete(ctx.issue, ctx.result, {:error, :timeout}, opts)
  end

  test "an unreadable journal on a check red on both head and base holds every poll", ctx do
    File.write!(ctx.opts[:ci_recovery_path], "[1]")
    opts = Keyword.put(ctx.opts, :main_watch_history, [base("failure")])
    assert %{decision: :pending, recovery: "base_inherited"} = Recovery.recover(ctx.issue, ctx.result, opts)
    assert %{decision: :pending, recovery: "base_inherited"} = Recovery.recover(ctx.issue, ctx.result, opts)
  end

  test "a transient rerun POST failure holds, then retries the POST once", ctx do
    digest = %FailureDigest{flake_only: true, checks: [%{id: 1, name: "test", url: @run_url}]}
    opts = ctx.opts |> Keyword.merge(main_watch_history: :disabled, request_fun: github(502)) |> Keyword.put(:ci_failure_digest, fn _, _ -> {:ok, digest} end)

    assert %{decision: :pending, recovery: "rerun_failed"} = Recovery.recover(ctx.issue, ctx.result, opts)
    assert_received {:rerun, _}
    assert_received {:attention, "ticket.3864.pr.ci_recovery.rerun_failed"}
    assert %{decision: :pending, recovery: "rerun_failed"} = Recovery.recover(ctx.issue, ctx.result, Keyword.put(opts, :ci_recovery_now, 1599))
    refute_received {:rerun, _}

    opts = Keyword.merge(opts, ci_recovery_now: 1600, request_fun: github(202))
    assert %{decision: :pending, recovery: "rerun_requested"} = Recovery.recover(ctx.issue, ctx.result, opts)
    assert_received {:rerun, _}
  end

  test "a cancelled required run gets one automatic rerun for the current head", ctx do
    result = Map.merge(ctx.result, %{decision: :pending, pending_reason: :ci_cancelled, failures: []})

    opts =
      Keyword.merge(ctx.opts,
        main_watch_history: :disabled,
        ci_recovery_observation: {:ok, %{"state" => "OPEN", "headRefOid" => "head", "isDraft" => false, "mergeQueueEntry" => nil, "autoMergeRequest" => nil}}
      )

    assert %{decision: :pending, recovery: "rerun_requested"} = Recovery.recover(ctx.issue, result, opts)
    assert_received {:rerun, url}
    assert url =~ "/actions/runs/99/rerun-failed-jobs"

    assert %{decision: :pending, recovery: "rerun_pending"} = Recovery.recover(ctx.issue, result, opts)
    refute_received {:rerun, _}
  end

  test "an Aiur-initiated cancellation is skipped", ctx do
    result = Map.merge(ctx.result, %{decision: :pending, pending_reason: :ci_cancelled, failures: []})
    assert :ok = CIRecoveryStore.record_cancelled_run("3864", 42, "head", 99, ctx.opts)

    assert %{decision: :pending} = Recovery.recover(ctx.issue, result, ctx.opts)
    refute_received {:rerun, _}
  end

  test "a newer run for the same workflow suppresses a stale cancelled run retry", ctx do
    result = Map.merge(ctx.result, %{decision: :pending, pending_reason: :ci_cancelled, failures: []})
    parent = self()

    request = fn req ->
      cond do
        req.method == :get and String.contains?(req.url, "/actions/runs?head_sha=") ->
          ok(%{"workflow_runs" => [%{"id" => 100, "head_sha" => "head", "name" => "ci"}]})

        req.method == :get ->
          ok(%{"id" => 99, "head_sha" => "head", "name" => "ci", "run_attempt" => 1, "status" => "completed", "conclusion" => "cancelled"})

        true ->
          send(parent, {:rerun, req.url})
          {:ok, %{status: 202, body: %{}, headers: []}}
      end
    end

    opts =
      Keyword.merge(ctx.opts,
        main_watch_history: :disabled,
        request_fun: request,
        ci_recovery_observation: {:ok, %{"state" => "OPEN", "headRefOid" => "head", "isDraft" => false, "mergeQueueEntry" => nil, "autoMergeRequest" => nil}}
      )

    assert %{decision: :pending} = Recovery.recover(ctx.issue, result, opts)
    refute_received {:rerun, _}
  end

  test "an approved auto-merge PR is not retried", ctx do
    result = Map.merge(ctx.result, %{decision: :pending, pending_reason: :ci_cancelled, failures: []})
    observation = %{"state" => "OPEN", "headRefOid" => "head", "isDraft" => false, "reviewDecision" => "APPROVED", "mergeQueueEntry" => nil, "autoMergeRequest" => %{"enabledAt" => "now"}}
    opts = Keyword.put(ctx.opts, :ci_recovery_observation, {:ok, observation})

    assert %{decision: :pending} = Recovery.recover(ctx.issue, result, opts)
    refute_received {:rerun, _}
  end

  test "a PR already in the merge queue is not retried", ctx do
    result = Map.merge(ctx.result, %{decision: :pending, pending_reason: :ci_cancelled, failures: []})
    observation = %{"state" => "OPEN", "headRefOid" => "head", "isDraft" => false, "reviewDecision" => nil, "mergeQueueEntry" => %{"id" => "MQE_1"}, "autoMergeRequest" => nil}
    opts = Keyword.put(ctx.opts, :ci_recovery_observation, {:ok, observation})

    assert %{decision: :pending, recovery: "merge_queue"} = Recovery.recover(ctx.issue, result, opts)
    refute_received {:rerun, _}
  end

  test "a required startup failure gets one automatic rerun for the current head", ctx do
    result = Map.put(ctx.result, :failures, [%{name: "test", result: "startup_failure", url: @run_url}])

    opts =
      Keyword.merge(ctx.opts,
        main_watch_history: :disabled,
        ci_recovery_observation: {:ok, %{"state" => "OPEN", "headRefOid" => "head", "isDraft" => false, "mergeQueueEntry" => nil, "autoMergeRequest" => nil}}
      )

    assert %{decision: :pending, recovery: "rerun_requested"} = Recovery.recover(ctx.issue, result, opts)
    assert_received {:rerun, url}
    assert url =~ "/actions/runs/99/rerun-failed-jobs"
  end

  test "supported infrastructure failure signals each get one exact-head rerun", ctx do
    failures = [
      %{name: "test", result: "timed_out", url: @run_url},
      %{name: "test", excerpt: "ECONNRESET", url: @run_url},
      %{name: "test", excerpt: "runner lost connection", url: @run_url},
      %{name: "test", excerpt: "artifact upload failed", url: @run_url}
    ]

    opts =
      Keyword.merge(ctx.opts,
        main_watch_history: :disabled,
        ci_recovery_observation: {:ok, %{"state" => "OPEN", "headRefOid" => "head", "isDraft" => false, "mergeQueueEntry" => nil, "autoMergeRequest" => nil}}
      )

    for {failure, index} <- Enum.with_index(failures) do
      result = Map.merge(ctx.result, %{pr_number: 100 + index, failures: [failure]})

      assert %{decision: :pending, recovery: "rerun_requested"} = Recovery.recover(ctx.issue, result, opts)
      assert_received {:rerun, url}
      assert url =~ "/actions/runs/99/rerun-failed-jobs"
    end
  end

  test "an approved head whose landing state is unreadable holds", ctx do
    result = Map.merge(ctx.result, %{review_decision: "APPROVED", auto_merge_request: nil, merge_queue_entry: nil})
    opts = Keyword.merge(ctx.opts, main_watch_history: :disabled, ci_recovery_observation: {:ok, %{"state" => "OPEN", "headRefOid" => "head"}})

    assert %{decision: :pending, recovery: "observation_unavailable"} = Recovery.recover(ctx.issue, result, opts)
    assert_received {:attention, "ticket.3864.pr.ci_recovery.observation_unavailable"}
    assert %{decision: :pending, recovery: "observation_unavailable"} = Recovery.recover(ctx.issue, result, Keyword.put(opts, :ci_recovery_now, 9999))
  end

  defp base(conclusion), do: %{sha: "base", checks: [%{name: "test", conclusion: conclusion}]}

  # An open, ready PR whose failed Actions run 99 answers rerun POSTs with `post_status`.
  defp github(post_status) do
    parent = self()

    fn
      %{method: :post, url: "https://api.github.com/graphql"} ->
        ok(%{"data" => %{"repository" => %{"pullRequest" => %{"state" => "OPEN", "headRefOid" => "head", "isDraft" => false, "reviewDecision" => nil, "mergeQueueEntry" => nil}}}})

      %{method: :post, url: url} ->
        send(parent, {:rerun, url})
        {:ok, %{status: post_status, body: %{}, headers: []}}

      %{method: :get, url: url} ->
        if String.contains?(url, "/actions/runs?head_sha=") do
          ok(%{"workflow_runs" => [%{"id" => 99, "head_sha" => "head", "name" => "ci"}]})
        else
          ok(%{"id" => 99, "head_sha" => "head", "name" => "ci", "run_attempt" => 1, "status" => "completed", "conclusion" => "failure"})
        end
    end
  end

  defp ok(body), do: {:ok, %{status: 200, body: body, headers: []}}
end
