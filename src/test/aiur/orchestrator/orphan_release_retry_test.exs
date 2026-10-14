defmodule Aiur.Orchestrator.OrphanReleaseRetryTest do
  use ExUnit.Case, async: false

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
