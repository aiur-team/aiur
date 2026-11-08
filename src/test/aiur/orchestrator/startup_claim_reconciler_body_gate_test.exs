defmodule Aiur.Orchestrator.StartupClaimReconcilerBodyGateTest do
  use ExUnit.Case, async: false

  alias Aiur.Issue
  alias Aiur.Orchestrator.{StartupClaimReconciler, State}

  @head String.duplicate("c", 40)
  @stale String.duplicate("a", 40)

  defp body(tested), do: "## Local tests\n\nPolicy: partial\nTested head: #{tested}\nBase: main @ #{String.duplicate("d", 40)}\nSelection: focused\n- `mix test` -> ok\n"

  defp release(pr_body) do
    parent = self()
    issue = %Issue{id: "issue-7822", identifier: "7822", title: "t", state: "in-progress"}

    opts = [
      grace_ms: 0,
      open_pr_fetcher: fn _ -> {:ok, %{"number" => 7900, "body" => pr_body, "head" => %{"sha" => @head}}} end,
      pr_fetcher: fn _ -> {:ok, %{"number" => 7900, "draft" => false, "mergeable" => true, "head" => %{"sha" => @head}}} end,
      unresolved_threads_fetcher: fn _ -> {:ok, []} end,
      reviews_fetcher: fn _ -> {:ok, []} end,
      pull_request_approval_fetcher: fn _ -> {:error, :not_approved} end,
      commit_ci_status_fetcher: fn _ -> {:ok, %{check_runs: [], commit_status: %{"state" => "success"}}} end,
      update_issue_state_fun: fn "7822", target, "in-progress" ->
        send(parent, {:released_to, target})
        :ok
      end,
      create_comment_fun: fn _, _ -> :ok end,
      emit_alert_fun: fn _, _ -> :ok end
    ]

    StartupClaimReconciler.reconcile(%State{}, [issue], opts)
  end

  test "an orphan with a stale PR body is released to rework, not to review" do
    release(body(@stale))
    assert_received {:released_to, "rework"}
  end

  test "an orphan with a current PR body still reaches review (guard against over-blocking)" do
    release(body(@head))
    assert_received {:released_to, target}
    assert target in ["human-review", "ci-wait"]
  end
end
