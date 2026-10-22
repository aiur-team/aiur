defmodule Aiur.Events.GithubCIPoller.ApprovedLandingRecoveryTest do
  use Aiur.TestSupport

  alias Aiur.Events.GithubCIPoller.Recovery
  alias Aiur.Issue

  setup do
    root = Aiur.TestSupport.tmp_root!("approved_landing_recovery")
    File.mkdir_p!(root)
    parent = self()
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    opts = [
      token: "test-gh-token",
      ci_recovery_path: Path.join(root, "recovery.json"),
      ci_recovery_enabled: false,
      alert_emitter: fn topic, _details ->
        send(parent, {:attention, topic})
        :ok
      end
    ]

    result = %{pr_number: 42, head_sha: "head", decision: :failed, failures: [%{name: "ci gate"}], review_decision: "APPROVED", auto_merge_request: nil, merge_queue_entry: nil}
    %{issue: %Issue{id: "1", identifier: "1"}, result: result, opts: opts}
  end

  test "an auto-merge observation holds the approved head and is cached for later polls", ctx do
    opts = with_observation(ctx.opts, {:ok, live_pr(%{"autoMergeRequest" => %{"enabledAt" => "2026-10-16T07:54:08Z"}})})

    assert %{decision: :pending, recovery: "approved_landing_pr"} = Recovery.recover(ctx.issue, ctx.result, opts)
    refute_received {:attention, _}

    assert %{decision: :pending, recovery: "approved_landing_pr"} = Recovery.recover(ctx.issue, ctx.result, with_observation(ctx.opts, {:error, :should_not_read}))
  end

  test "a cancelled head run while queued does not create a recovery hold or attention", ctx do
    result = Map.merge(ctx.result, %{decision: :pending, pending_reason: :ci_cancelled, merge_queue_entry: %{"id" => "MQE_1"}})

    assert ^result = Recovery.recover(ctx.issue, result, ctx.opts)
    refute_received {:attention, _}
  end

  test "the cached landing hold stops applying once the PR is no longer approved", ctx do
    opts = with_observation(ctx.opts, {:ok, live_pr(%{"autoMergeRequest" => %{"enabledAt" => "2026-10-16T07:54:08Z"}})})
    assert %{decision: :pending} = Recovery.recover(ctx.issue, ctx.result, opts)

    assert %{decision: :failed} = Recovery.recover(ctx.issue, %{ctx.result | review_decision: "CHANGES_REQUESTED"}, opts)
  end

  test "an approved PR observed not landing still routes its failure", ctx do
    opts = with_observation(ctx.opts, {:ok, live_pr(%{})})

    assert %{decision: :failed} = Recovery.recover(ctx.issue, ctx.result, opts)
  end

  test "changes requested routes without a landing read", ctx do
    result = %{ctx.result | review_decision: "CHANGES_REQUESTED"}
    assert %{decision: :failed} = Recovery.recover(ctx.issue, result, with_observation(ctx.opts, {:error, :should_not_read}))
  end

  test "an approval recorded on an older head routes the new head's failure without a landing read", ctx do
    result = Map.put(ctx.result, :approved_review_head_sha, "older-head")
    assert %{decision: :failed} = Recovery.recover(ctx.issue, result, with_observation(ctx.opts, {:error, :should_not_read}))
  end

  test "an unavailable landing observation holds with one attention", ctx do
    opts = with_observation(ctx.opts, {:error, :timeout})

    assert %{decision: :pending, recovery: "observation_unavailable"} = Recovery.recover(ctx.issue, ctx.result, opts)
    assert_received {:attention, "ticket.1.pr.ci_recovery.observation_unavailable"}

    assert %{decision: :pending} = Recovery.recover(ctx.issue, ctx.result, with_observation(ctx.opts, {:ok, live_pr(%{})}))
    refute_received {:attention, _}
  end

  defp with_observation(opts, observation), do: Keyword.put(opts, :ci_recovery_observation, observation)

  defp live_pr(fields),
    do: Map.merge(%{"state" => "OPEN", "headRefOid" => "head", "isDraft" => false, "reviewDecision" => "APPROVED", "autoMergeRequest" => nil, "mergeQueueEntry" => nil}, fields)
end
