defmodule Aiur.Events.GithubCIPollerBudgetHoldTest do
  use Aiur.TestSupport
  import Aiur.TestSupport.CIPollerFixture

  alias Aiur.Events.GithubCIPoller

  setup :ci_poller_env

  test "required-check budget hold quarantines failures and does not withdraw approved landing" do
    pr = %{
      "number" => 71,
      "head" => pr_head("aiur/42", "current-head"),
      "base" => %{"ref" => "main"},
      "merge_queue" => %{
        draft?: false,
        review_decision: "APPROVED",
        mergeable: "MERGEABLE",
        merge_state_status: "BLOCKED",
        auto_merge_request: nil,
        merge_queue_entry: %{"id" => "queue-entry", "state" => "AWAITING_CHECKS"}
      }
    }

    check_runs = [
      check_run(100, 1, "failure", "2026-10-24T06:00:00Z"),
      check_run(100, 2, "success", "2026-10-24T06:10:00Z")
    ]

    batch = %{"42" => %{pull_request: pr, check_runs: check_runs, commit_status: %{"statuses" => []}}}

    assert {:ok, %{results: [result]}} =
             poll(["42"],
               ci_batch: batch,
               required_check_fetcher: fn _ -> {:error, {:aiur, :locally_held, :core}} end
             )

    assert result.decision == :pending
    assert result.pending_reason == :required_checks_unavailable
    refute result[:approved_landing_withdrawn?]

    assert ^result =
             GithubCIPoller.recover_failure(%{identifier: "42"}, result, withdraw_landing: fn _ -> flunk("unavailable required checks must never withdraw landing") end)
  end

  test "a later same-workflow success supersedes a failure from another suite" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    older = DateTime.add(now, -120, :second) |> DateTime.to_iso8601()
    newer = DateTime.add(now, -60, :second) |> DateTime.to_iso8601()

    runs = [check_run(10, 10, "failure", older), check_run(10, 11, "success", newer)]
    pr = %{"number" => 71, "head" => pr_head("aiur/42", "current-head"), "base" => %{"ref" => "main"}, "draft" => false}
    batch = %{"42" => %{pull_request: pr, check_runs: runs, commit_status: %{"statuses" => []}}}

    assert {:ok, %{results: [%{decision: :passed, failures: []}]}} =
             poll(["42"], ci_batch: batch, required_check_fetcher: fn _ -> {:ok, []} end)
  end

  defp check_run(workflow_id, suite_id, conclusion, started_at) do
    %{
      "name" => "pr body",
      "workflow_id" => workflow_id,
      "check_suite_id" => suite_id,
      "status" => "completed",
      "conclusion" => conclusion,
      "started_at" => started_at
    }
  end
end
