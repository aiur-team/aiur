defmodule Aiur.Events.GithubCIPoller.RecoveryBaseGateTest do
  use Aiur.TestSupport

  alias Aiur.CI.FailureDigest
  alias Aiur.Events.GithubCIPoller.Recovery
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

      %{method: :get} ->
        ok(%{"head_sha" => "head", "run_attempt" => 1, "status" => "completed", "conclusion" => "failure"})
    end
  end

  defp ok(body), do: {:ok, %{status: 200, body: body, headers: []}}
end
