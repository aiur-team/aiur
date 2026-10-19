defmodule Aiur.Orchestrator.CiRecoveryPolicyTest do
  use Aiur.TestSupport

  alias Aiur.CI.FailureDigest
  alias Aiur.Events.GithubCIPoller.Recovery
  alias Aiur.GitHub.CIRecoveryStore
  alias Aiur.Issue

  setup do
    root = Aiur.TestSupport.tmp_root!("ci_recovery_policy")
    File.mkdir_p!(root)
    path = Path.join(root, "recovery.json")

    state =
      start_supervised!({Agent, fn -> %{posts: [], conclusion: "failure", draft: false, review: nil} end})

    request = fn
      %{method: :post, url: "https://api.github.com/graphql"} ->
        current = Agent.get(state, & &1)
        ok(%{"data" => %{"repository" => %{"pullRequest" => %{"state" => "OPEN", "headRefOid" => "head", "isDraft" => current.draft, "reviewDecision" => current.review, "mergeQueueEntry" => nil}}}})

      %{method: :post, url: url} ->
        Agent.update(state, &Map.update!(&1, :posts, fn posts -> [url | posts] end))
        ok(%{})

      %{method: :get, url: url} ->
        if String.ends_with?(url, "/actions/runs/99"),
          do: ok(%{"head_sha" => "head", "run_attempt" => 1, "status" => "completed", "conclusion" => Agent.get(state, & &1.conclusion)}),
          else: flunk("unexpected GET #{url}")
    end

    digest = %FailureDigest{flake_only: true, checks: [%{id: 1, name: "test", url: "https://github.com/owner/repo/actions/runs/99/job/1"}]}

    opts = [
      token: "test-gh-token",
      request_fun: request,
      ci_recovery_path: path,
      ci_failure_digest: fn _, _ -> {:ok, digest} end,
      alert_emitter: fn topic, details ->
        send(self(), {:attention, topic, details})
        :ok
      end
    ]

    %{state: state, issue: %Issue{id: "1", identifier: "1"}, result: %{pr_number: 42, head_sha: "head", decision: :failed, failures: [%{name: "test"}]}, opts: opts}
  end

  test "cancelled runs are skipped with one neutral attention", ctx do
    Agent.update(ctx.state, &%{&1 | conclusion: "cancelled"})
    assert %{decision: :failed, recovery: nil} = recover(ctx)
    assert Agent.get(ctx.state, & &1.posts) == []
    assert_received {:attention, "ticket.1.pr.ci_recovery.rerun_skipped", details}
    assert details[:message] =~ "cancelled_run"
    recover(ctx)
    refute_received {:attention, _, _}
  end

  test "draft PRs are skipped", ctx do
    Agent.update(ctx.state, &%{&1 | draft: true})
    assert %{decision: :failed, recovery: nil} = recover(ctx)
    assert Agent.get(ctx.state, & &1.posts) == []
    assert_received {:attention, "ticket.1.pr.ci_recovery.rerun_skipped", _}
  end

  test "changes-requested PRs are skipped", ctx do
    Agent.update(ctx.state, &%{&1 | review: "CHANGES_REQUESTED"})
    assert %{decision: :failed, recovery: nil} = recover(ctx)
    assert Agent.get(ctx.state, & &1.posts) == []
    assert_received {:attention, "ticket.1.pr.ci_recovery.rerun_skipped", _}
  end

  test "fifty eligible tickets issue no more than the per-poll cap", ctx do
    opts = Keyword.put(ctx.opts, :ci_recovery_poll_id, make_ref())

    for number <- 1..50 do
      issue = %{ctx.issue | id: "#{number}", identifier: "#{number}"}
      Recovery.recover(issue, ctx.result, opts)
    end

    assert length(Agent.get(ctx.state, & &1.posts)) == 5
  end

  test "hourly limit applies across separate polls", ctx do
    digest = fn _, _ ->
      send(self(), :digest_built)
      {:ok, %FailureDigest{flake_only: true, checks: [%{id: 1, name: "test", url: "https://github.com/owner/repo/actions/runs/99/job/1"}]}}
    end

    opts = ctx.opts |> Keyword.put(:ci_recovery_now, 1_000) |> Keyword.put(:ci_failure_digest, digest)

    for number <- 1..50 do
      issue = %{ctx.issue | id: "#{number}", identifier: "#{number}"}
      Recovery.recover(issue, ctx.result, Keyword.put(opts, :ci_recovery_poll_id, make_ref()))
    end

    assert length(Agent.get(ctx.state, & &1.posts)) == 20
    for _ <- 1..50, do: assert_received(:digest_built)

    for number <- 21..50 do
      issue = %{ctx.issue | id: "#{number}", identifier: "#{number}"}
      assert %{recovery: "rerun_limit"} = Recovery.recover(issue, ctx.result, Keyword.put(opts, :ci_recovery_poll_id, make_ref()))
    end

    refute_received :digest_built
  end

  test "rerun reservations admit a ticket atomically", ctx do
    assert :ok = CIRecoveryStore.reserve_reruns(:poll, 1, 2, 20, ctx.opts)
    assert {:error, :poll_limit_reached} = CIRecoveryStore.reserve_reruns(:poll, 2, 2, 20, ctx.opts)
    assert :ok = CIRecoveryStore.reserve_reruns(:poll, 1, 2, 20, ctx.opts)

    assert :ok = CIRecoveryStore.reserve_reruns(:new_poll, 2, 2, 20, ctx.opts)
    assert {:error, :poll_limit_reached} = CIRecoveryStore.reserve_reruns(:new_poll, 1, 2, 20, ctx.opts)

    hourly_opts =
      ctx.opts
      |> Keyword.put(:ci_recovery_path, ctx.opts[:ci_recovery_path] <> ".hourly")
      |> Keyword.put(:ci_recovery_max_reruns_per_hour, 3)

    assert :ok = CIRecoveryStore.reserve_reruns(:hour_poll, 2, 2, 3, hourly_opts)
    assert {:error, {:hour_limit_reached, _}} = CIRecoveryStore.reserve_reruns(:other_poll, 2, 2, 3, hourly_opts)
  end

  test "automatic reruns can be disabled without recovery reads", ctx do
    opts = Keyword.put(ctx.opts, :ci_recovery_enabled, false)
    assert %{decision: :failed} = Recovery.recover(ctx.issue, ctx.result, opts)
    assert Agent.get(ctx.state, & &1.posts) == []
    refute_received {:attention, _, _}
  end

  defp recover(ctx), do: Recovery.recover(ctx.issue, ctx.result, ctx.opts)
  defp ok(body), do: {:ok, %{status: 200, body: body, headers: []}}
end
