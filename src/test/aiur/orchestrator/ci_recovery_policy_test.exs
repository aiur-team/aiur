defmodule Aiur.Orchestrator.CiRecoveryPolicyTest do
  use Aiur.TestSupport

  alias Aiur.CI.FailureDigest
  alias Aiur.Events.GithubCIPoller.Recovery
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
    assert %{recovery: "rerun_skipped"} = recover(ctx)
    assert Agent.get(ctx.state, & &1.posts) == []
    assert_received {:attention, "ticket.1.pr.ci_recovery.rerun_skipped", details}
    assert details[:message] =~ "cancelled_run"
    recover(ctx)
    refute_received {:attention, _, _}
  end

  test "draft PRs are skipped", ctx do
    Agent.update(ctx.state, &%{&1 | draft: true})
    assert %{recovery: "rerun_skipped"} = recover(ctx)
    assert Agent.get(ctx.state, & &1.posts) == []
    assert_received {:attention, "ticket.1.pr.ci_recovery.rerun_skipped", _}
  end

  test "changes-requested PRs are skipped", ctx do
    Agent.update(ctx.state, &%{&1 | review: "CHANGES_REQUESTED"})
    assert %{recovery: "rerun_skipped"} = recover(ctx)
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
    for number <- 1..50 do
      issue = %{ctx.issue | id: "#{number}", identifier: "#{number}"}
      Recovery.recover(issue, ctx.result, Keyword.put(ctx.opts, :ci_recovery_poll_id, make_ref()))
    end

    assert length(Agent.get(ctx.state, & &1.posts)) == 20
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
