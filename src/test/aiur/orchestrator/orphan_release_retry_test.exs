defmodule Aiur.Orchestrator.OrphanReleaseRetryTest do
  use ExUnit.Case, async: false

  # These tests keep startup-release routing beside its retry behavior: both
  # assert the state and durable comment produced by orphan recovery.

  alias Aiur.Issue
  alias Aiur.Orchestrator.{StartupClaimReconciler, State}

  test "stale review base sends unapproved PR to rework" do
    opts =
      Keyword.merge(opts(),
        open_pr_fetcher: fn _ -> {:ok, %{"number" => 42}} end,
        pr_fetcher: fn 42 -> {:ok, %{"number" => 42, "mergeable" => true, "head" => %{"sha" => "head"}}} end,
        unresolved_threads_fetcher: fn _ -> {:ok, []} end,
        reviews_fetcher: fn _ -> {:ok, []} end,
        approved_at_head_fetcher: fn 42 -> {:ok, false} end,
        update_issue_state_fun: fn "3710", target, "in-progress" ->
          send(self(), {:write, target})
          if target == "human-review", do: {:error, {:stale_review_base, %{pr_number: 42}}}, else: :ok
        end
      )

    {_released, [result]} = StartupClaimReconciler.reconcile(%State{}, [issue()], opts)
    assert result.state == "rework"
    assert_received {:write, "human-review"}
    assert_received {:write, "rework"}
    assert_received {:comment, body}
    assert body =~ "Integrate the base, push, and hand it back."
  end

  test "stale review base defers an approved head without consuming retries" do
    opts =
      Keyword.merge(opts(),
        open_pr_fetcher: fn _ -> {:ok, %{"number" => 42}} end,
        pr_fetcher: fn 42 -> {:ok, %{"number" => 42, "mergeable" => true, "head" => %{"sha" => "head"}}} end,
        unresolved_threads_fetcher: fn _ -> {:ok, []} end,
        reviews_fetcher: fn _ -> {:ok, []} end,
        approved_at_head_fetcher: fn 42 -> {:ok, true} end,
        update_issue_state_fun: fn "3710", target, "in-progress" ->
          send(self(), {:write, target})
          if target == "human-review", do: {:error, {:stale_review_base, %{pr_number: 42}}}, else: :ok
        end
      )

    {released, [result]} = StartupClaimReconciler.reconcile(%State{}, [issue()], opts)
    assert result.state == "in-progress"
    assert released.startup_claim_reconciliation_failures["3710"].attempts == 0
    assert_received {:write, "human-review"}
    refute_received {:write, "rework"}
    refute_received {:comment, _}
  end

  test "stale review base defers when approval status cannot be verified" do
    opts =
      Keyword.merge(opts(),
        open_pr_fetcher: fn _ -> {:ok, %{"number" => 42}} end,
        pr_fetcher: fn 42 -> {:ok, %{"number" => 42, "mergeable" => true, "head" => %{"sha" => "head"}}} end,
        unresolved_threads_fetcher: fn _ -> {:ok, []} end,
        reviews_fetcher: fn _ -> {:ok, []} end,
        approved_at_head_fetcher: fn 42 -> {:error, :timeout} end,
        update_issue_state_fun: fn "3710", target, "in-progress" ->
          send(self(), {:write, target})
          if target == "human-review", do: {:error, {:stale_review_base, %{pr_number: 42}}}, else: :ok
        end
      )

    {released, [result]} = StartupClaimReconciler.reconcile(%State{}, [issue()], opts)
    assert result.state == "in-progress"
    assert released.startup_claim_reconciliation_failures["3710"].attempts == 0
    assert_received {:write, "human-review"}
    refute_received {:write, "rework"}
    refute_received {:comment, _}
  end

  # #3971: a never-reviewed PR is the reviewer's, however sticky an old verdict on another head is.
  test "an open pull request with no review on its head is released to human-review" do
    stale = %{"state" => "CHANGES_REQUESTED", "commit_id" => "older", "user" => %{"login" => "reviewer"}, authoritative: true}

    for reviews <- [[], [stale]] do
      opts =
        Keyword.merge(opts(),
          open_pr_fetcher: fn _ -> {:ok, %{"number" => 42}} end,
          pr_fetcher: fn 42 -> {:ok, %{"number" => 42, "mergeable" => true, "head" => %{"sha" => "head"}}} end,
          unresolved_threads_fetcher: fn _ -> {:ok, []} end,
          reviews_fetcher: fn _ -> {:ok, reviews} end
        )

      {_released, [result]} = StartupClaimReconciler.reconcile(%State{}, [issue()], opts)
      assert result.state == "human-review"
      assert_received {:comment, body}
      assert body =~ "to human-review"
      refute body =~ "Integrate the base"
    end
  end

  test "restart keeps an unresolved review on an older head in human-review" do
    stale = %{"state" => "CHANGES_REQUESTED", "commit_id" => "older", "user" => %{"login" => "reviewer"}, authoritative: true}

    opts =
      Keyword.merge(opts(),
        open_pr_fetcher: fn _ -> {:ok, %{"number" => 42}} end,
        pr_fetcher: fn 42 -> {:ok, %{"number" => 42, "mergeable" => true, "head" => %{"sha" => "head"}}} end,
        unresolved_threads_fetcher: fn _ -> {:ok, [%{"id" => "old-thread", "isResolved" => false}]} end,
        reviews_fetcher: fn 42 -> {:ok, [stale]} end
      )

    {_released, [%Issue{state: "human-review"}]} = StartupClaimReconciler.reconcile(%State{}, [issue()], opts)
    assert_received {:comment, body}
    assert body =~ "to human-review"
    refute body =~ "to rework"
  end

  test "restart routes an unresolved review on the current head to rework" do
    current = %{"state" => "CHANGES_REQUESTED", "commit_id" => "head", "user" => %{"login" => "reviewer"}, authoritative: true}

    opts =
      Keyword.merge(opts(),
        open_pr_fetcher: fn _ -> {:ok, %{"number" => 42}} end,
        pr_fetcher: fn 42 -> {:ok, %{"number" => 42, "mergeable" => true, "head" => %{"sha" => "head"}}} end,
        unresolved_threads_fetcher: fn _ -> {:ok, [%{"id" => "current-thread", "isResolved" => false}]} end,
        reviews_fetcher: fn 42 -> {:ok, [current]} end
      )

    {_released, [%Issue{state: "rework"}]} = StartupClaimReconciler.reconcile(%State{}, [issue()], opts)
    assert_received {:comment, body}
    assert body =~ "to rework"
  end

  test "an orphaned claim with a current-head approval is released to ci-wait" do
    approval = %{"state" => "APPROVED", "commit_id" => "head", "user" => %{"login" => "reviewer"}, :authoritative => true}

    opts =
      Keyword.merge(opts(),
        open_pr_fetcher: fn _ -> {:ok, %{"number" => 42}} end,
        pr_fetcher: fn 42 -> {:ok, %{"number" => 42, "mergeable" => true, "head" => %{"sha" => "head"}}} end,
        unresolved_threads_fetcher: fn _ -> {:ok, []} end,
        reviews_fetcher: fn _ -> {:ok, [approval]} end,
        pull_request_approval_fetcher: fn 42 -> {:ok, {"head", "head"}} end,
        update_issue_state_fun: fn "3710", target, "in-progress" ->
          send(self(), {:write, target})
          :ok
        end
      )

    {_released, [%Issue{state: "ci-wait"}]} = StartupClaimReconciler.reconcile(%State{}, [issue()], opts)
    assert_received {:write, "ci-wait"}
    assert_received {:comment, body}
    assert body =~ "to ci-wait"
    refute_received {:write, "human-review"}
  end

  for reason <- [
        {:github, :local_hold, %{reason: {:aiur, :locally_held, %{reason: :shared_budget, reset_at: 100}}}},
        {:aiur, :locally_held, %{reason: :shared_budget, reset_at: 100}},
        {:github, :transport, %{reason: {:aiur, :locally_held, %{reset_at: 100}}}},
        {:github, :rate_limited, %{reset_at: 100}}
      ] do
    test "budget hold #{inspect(reason)} preserves attempts until reset" do
      issue = issue()
      state = %State{startup_claim_reconciliation_failures: %{"3710" => %{attempts: 2, reason: :write_failed}}}
      held_opts = Keyword.put(opts(), :update_issue_state_fun, fn _, _, _ -> {:error, unquote(Macro.escape(reason))} end)

      held =
        Enum.reduce(1..4, state, fn _, current ->
          {next, [^issue]} = StartupClaimReconciler.reconcile(current, [issue], held_opts)
          refute next.startup_claim_reconciliation_complete?
          assert next.startup_claim_reconciliation_failures["3710"].attempts == 2
          next
        end)

      refute_received {:comment, _}
      {released, [%Issue{state: "todo"}]} = StartupClaimReconciler.reconcile(held, [issue], opts())
      assert released.startup_claim_reconciliation_failures == %{}
      assert released.orphaned_claim_since == %{}
      assert_received {:comment, _}
    end
  end

  # #4791: a cold-start budget hold clears within seconds, so it must not page the Executor.
  test "a short budget hold retries quietly and releases without any alert" do
    held_opts = Keyword.put(hold_opts(self()), :now_ms, 0)
    {held, [_issue]} = StartupClaimReconciler.reconcile(%State{}, [issue()], held_opts)
    refute held.startup_claim_reconciliation_complete?

    released_opts = Keyword.merge(held_opts, update_issue_state_fun: fn _, _, _ -> :ok end, now_ms: 60_000)
    {released, [%Issue{state: "todo"}]} = StartupClaimReconciler.reconcile(held, [issue()], released_opts)
    assert released.startup_claim_reconciliation_failures == %{}
    refute_received {:alert, "ticket.3710.agent.attention.startup_claim_reconciliation_failed" <> _, _}
  end

  test "a budget hold lasting ten minutes raises one attention and keeps retrying" do
    opts = hold_opts(self())

    held =
      Enum.reduce(0..1_200_000//30_000, %State{}, fn now, current ->
        {next, [_issue]} = StartupClaimReconciler.reconcile(current, [issue()], Keyword.put(opts, :now_ms, now))
        next
      end)

    assert_received {:alert, "ticket.3710.agent.attention.startup_claim_reconciliation_failed", alert}
    assert alert[:message] =~ "over 10 min"
    assert alert[:needs_attention]
    refute_received {:alert, _, _}
    assert held.startup_claim_reconciliation_failures["3710"].attempts == 0

    {_released, [%Issue{state: "todo"}]} =
      StartupClaimReconciler.reconcile(held, [issue()], Keyword.merge(opts, update_issue_state_fun: fn _, _, _ -> :ok end, now_ms: 1_230_000))

    assert_received {:alert, "ticket.3710.agent.attention.startup_claim_reconciliation_failed.resolved", _}
  end

  defp hold_opts(test_pid) do
    Keyword.merge(opts(),
      update_issue_state_fun: fn _, _, _ -> {:error, {:aiur, :locally_held, %{reason: :shared_budget, resource: "core", reset_at: 100}}} end,
      emit_alert_fun: fn topic, alert ->
        send(test_pid, {:alert, topic, alert})
        :ok
      end
    )
  end

  # #4826: a draft is still being worked, so it is never offered to a reviewer.
  test "an open draft pull request is released to rework" do
    opts =
      Keyword.merge(opts(),
        open_pr_fetcher: fn _ -> {:ok, %{"number" => 42}} end,
        pr_fetcher: fn 42 -> {:ok, %{"number" => 42, "draft" => true, "mergeable" => true, "head" => %{"sha" => "head"}}} end,
        unresolved_threads_fetcher: fn _ -> {:ok, []} end,
        reviews_fetcher: fn _ -> {:ok, []} end,
        update_issue_state_fun: fn "3710", target, "in-progress" ->
          send(self(), {:write, target})
          :ok
        end
      )

    {_released, [result]} = StartupClaimReconciler.reconcile(%State{}, [issue()], opts)
    assert result.state == "rework"
    assert_received {:write, "rework"}
    refute_received {:write, "human-review"}
  end

  # #4826: boot-time budget timeouts starve the ancestry read; retry with backoff, never latch.
  test "unavailable review-base ancestry retries with backoff until it resolves" do
    test_pid = self()

    failing =
      Keyword.merge(opts(),
        open_pr_fetcher: fn _ -> {:ok, %{"number" => 42}} end,
        pr_fetcher: fn 42 -> {:ok, %{"number" => 42, "mergeable" => true, "head" => %{"sha" => "head"}}} end,
        unresolved_threads_fetcher: fn _ -> {:ok, []} end,
        reviews_fetcher: fn _ -> {:ok, []} end,
        update_issue_state_fun: fn "3710", target, "in-progress" ->
          send(test_pid, {:write, target})
          {:error, :review_base_ancestry_unavailable}
        end
      )

    # Writes at 0, 30s, 90s, 210s and 450s; polls in between are backing off.
    held =
      Enum.reduce([0, 10_000, 30_000, 60_000, 90_000, 210_000, 450_000], %State{}, fn now, current ->
        {next, [%Issue{state: "in-progress"}]} = StartupClaimReconciler.reconcile(current, [issue()], Keyword.put(failing, :now_ms, now))
        refute next.startup_claim_reconciliation_complete?
        assert next.startup_claim_reconciliation_failures["3710"].attempts == 0
        next
      end)

    for _ <- 1..5, do: assert_received({:write, "human-review"})
    refute_received {:write, _}
    assert held.startup_claim_reconciliation_failures["3710"].retry_at == 450_000 + 480_000

    {early, _} = StartupClaimReconciler.reconcile(held, [issue()], Keyword.put(failing, :now_ms, 900_000))
    refute_received {:write, _}

    resolved =
      Keyword.put(failing, :update_issue_state_fun, fn "3710", target, "in-progress" ->
        send(test_pid, {:write, target})
        :ok
      end)

    {released, [%Issue{state: "human-review"}]} = StartupClaimReconciler.reconcile(early, [issue()], Keyword.put(resolved, :now_ms, 930_000))
    assert_received {:write, "human-review"}
    assert released.startup_claim_reconciliation_failures == %{}
    assert released.startup_claim_reconciliation_complete?
  end

  # #4842: a deferral does not use up attempts, so its first alert must not promise a bounded retry count.
  test "the first unavailable-ancestry alert describes the backoff retry" do
    opts = ancestry_unavailable_opts(self())
    {_held, _} = StartupClaimReconciler.reconcile(%State{}, [issue()], Keyword.put(opts, :now_ms, 0))

    assert_received {:alert, "ticket.3710.agent.attention.startup_claim_reconciliation_failed", alert}
    assert alert[:reason] =~ "retried with backoff"
    assert alert[:reason] =~ "without using up release attempts"
    refute alert[:reason] =~ "up to 3 times"
    refute_received {:alert, _, _}
  end

  # #4842: some ancestry failures never clear, so alert once after an hour and keep backing off quietly.
  test "persistent unavailable ancestry raises one attention after an hour and keeps backing off" do
    opts = ancestry_unavailable_opts(self())

    held =
      Enum.reduce(0..7_200_000//30_000, %State{}, fn now, current ->
        {next, [%Issue{state: "in-progress"}]} = StartupClaimReconciler.reconcile(current, [issue()], Keyword.put(opts, :now_ms, now))
        next
      end)

    assert_received {:alert, _topic, first}
    refute first[:message] =~ "over an hour"
    assert_received {:alert, "ticket.3710.agent.attention.startup_claim_reconciliation_failed", persistent}
    assert persistent[:message] =~ "over an hour"
    assert persistent[:reason] =~ "300 or more files or over 100 commits"
    assert persistent[:needs_attention]
    refute_received {:alert, _, _}

    entry = held.startup_claim_reconciliation_failures["3710"]
    assert entry.persistent_alerted
    assert entry.attempts == 0
    assert entry.retry_at > 7_200_000
    refute held.startup_claim_reconciliation_complete?
  end

  defp ancestry_unavailable_opts(test_pid) do
    Keyword.merge(opts(),
      open_pr_fetcher: fn _ -> {:ok, %{"number" => 42}} end,
      pr_fetcher: fn 42 -> {:ok, %{"number" => 42, "mergeable" => true, "head" => %{"sha" => "head"}}} end,
      unresolved_threads_fetcher: fn _ -> {:ok, []} end,
      reviews_fetcher: fn _ -> {:ok, []} end,
      update_issue_state_fun: fn "3710", _target, "in-progress" -> {:error, :review_base_ancestry_unavailable} end,
      emit_alert_fun: fn topic, alert ->
        send(test_pid, {:alert, topic, alert})
        :ok
      end
    )
  end

  defp issue, do: %Issue{id: "issue-3710", identifier: "3710", state: "in-progress", title: "Orphan"}

  defp opts do
    [
      grace_ms: 0,
      ownership_fun: fn _ -> :none end,
      open_pr_fetcher: fn _ -> {:ok, nil} end,
      update_issue_state_fun: fn _, _, _ -> :ok end,
      create_comment_fun: fn _, body ->
        send(self(), {:comment, body})
        :ok
      end,
      emit_alert_fun: fn _, _ -> :ok end
    ]
  end
end
