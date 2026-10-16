defmodule Aiur.Events.GithubCIPoller.ApprovedLandingRecoveryTest do
  use Aiur.TestSupport

  alias Aiur.Events.GithubCIPoller.Recovery
  alias Aiur.Issue

  setup do
    root = Aiur.TestSupport.tmp_root!("approved_landing_recovery")
    File.mkdir_p!(root)

    opts = [
      token: "test-gh-token",
      ci_recovery_path: Path.join(root, "recovery.json"),
      ci_recovery_enabled: false,
      alert_emitter: fn topic, _details ->
        send(self(), {:attention, topic})
        :ok
      end
    ]

    result = %{pr_number: 42, head_sha: "head", decision: :failed, failures: [%{name: "ci gate"}], review_decision: "APPROVED", auto_merge_request: nil, merge_queue_entry: nil}
    %{issue: %Issue{id: "1", identifier: "1"}, result: result, opts: opts}
  end

  test "a live auto-merge read holds the approved head and is cached for later polls", ctx do
    opts = with_live_pr(ctx.opts, %{"autoMergeRequest" => %{"enabledAt" => "2026-10-16T07:54:08Z"}})

    assert %{decision: :pending, recovery: "approved_landing_pr"} = Recovery.recover(ctx.issue, ctx.result, opts)
    assert_received :live_read
    refute_received {:attention, _}

    assert %{decision: :pending, recovery: "approved_landing_pr"} = Recovery.recover(ctx.issue, ctx.result, opts)
    refute_received :live_read
  end

  test "the cached landing hold stops applying once the PR is no longer approved", ctx do
    opts = with_live_pr(ctx.opts, %{"autoMergeRequest" => %{"enabledAt" => "2026-10-16T07:54:08Z"}})
    assert %{decision: :pending} = Recovery.recover(ctx.issue, ctx.result, opts)

    assert %{decision: :failed} = Recovery.recover(ctx.issue, %{ctx.result | review_decision: "CHANGES_REQUESTED"}, opts)
  end

  test "an approved PR the live read shows not landing still routes its failure", ctx do
    opts = with_live_pr(ctx.opts, %{})

    assert %{decision: :failed} = Recovery.recover(ctx.issue, ctx.result, opts)
    assert_received :live_read
  end

  test "changes requested routes without a landing read", ctx do
    result = %{ctx.result | review_decision: "CHANGES_REQUESTED"}
    assert %{decision: :failed} = Recovery.recover(ctx.issue, result, with_live_pr(ctx.opts, %{}))
    refute_received :live_read
  end

  test "an approval recorded on an older head routes the new head's failure without a landing read", ctx do
    result = Map.put(ctx.result, :approved_review_head_sha, "older-head")
    assert %{decision: :failed} = Recovery.recover(ctx.issue, result, with_live_pr(ctx.opts, %{}))
    refute_received :live_read
  end

  test "an unreadable landing state holds with one attention and no repeated read", ctx do
    parent = self()

    opts =
      Keyword.put(ctx.opts, :request_fun, fn _request ->
        send(parent, :live_read)
        {:error, :timeout}
      end)

    assert %{decision: :pending, recovery: "observation_unavailable"} = Recovery.recover(ctx.issue, ctx.result, opts)
    assert_received :live_read
    assert_received {:attention, "ticket.1.pr.ci_recovery.observation_unavailable"}

    assert %{decision: :pending} = Recovery.recover(ctx.issue, ctx.result, opts)
    refute_received :live_read
  end

  defp with_live_pr(opts, fields) do
    pr = Map.merge(%{"state" => "OPEN", "headRefOid" => "head", "isDraft" => false, "reviewDecision" => "APPROVED", "autoMergeRequest" => nil, "mergeQueueEntry" => nil}, fields)
    parent = self()

    Keyword.put(opts, :request_fun, fn %{url: "https://api.github.com/graphql"} ->
      send(parent, :live_read)
      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequest" => pr}}}, headers: []}}
    end)
  end
end
