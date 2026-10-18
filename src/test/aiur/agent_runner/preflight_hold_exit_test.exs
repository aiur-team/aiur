defmodule Aiur.AgentRunner.PreflightHoldExitTest do
  use Aiur.TestSupport

  alias Aiur.AgentRunner
  alias Aiur.Issue
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.State

  @issue %Issue{id: "issue-4679", identifier: "MT-4679", title: "preflight hold"}

  describe "workspace auth preflight failure exit (#4679)" do
    test "a local budget hold defers until reset_at without consuming a retry" do
      hold = %{reason: :shared_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), 30, :second)}

      reason =
        {:workspace_github_connectivity_failed, "/workspaces/4679", {:github_auth_preflight_failed, %{classification: :local_hold, detail: %{reason: {:aiur, :locally_held, hold}, hold: hold}}}}

      exit_reason = catch_exit(AgentRunner.handle_run_error(@issue, reason))
      assert exit_reason == reason

      retry = agent_down_retry(exit_reason)
      assert retry.attempt == 2
      assert retry.delay_type == :local_budget_hold
      refute RetryEngine.failure_retry?(retry)

      delay = retry.due_at_ms - System.monotonic_time(:millisecond)
      assert delay > 25_000 and delay <= 31_000
      Process.cancel_timer(retry.timer_ref)
    end

    test "a 401 preflight answer still counts as a failed attempt" do
      reason =
        {:workspace_github_connectivity_failed, "/workspaces/4679", {:github_auth_preflight_failed, %{classification: :auth, status: 401, message: "Bad credentials"}}}

      error = assert_raise RuntimeError, fn -> AgentRunner.handle_run_error(@issue, reason) end

      retry = agent_down_retry({error, []})
      assert retry.attempt == 3
      assert RetryEngine.failure_retry?(retry)
      Process.cancel_timer(retry.timer_ref)
    end
  end

  defp agent_down_retry(exit_reason) do
    issue_id = @issue.id
    ref = make_ref()

    state = %State{
      running: %{
        issue_id => %{ref: ref, identifier: @issue.identifier, started_at: DateTime.utc_now(), retry_attempt: 2, worker_host: nil, workspace_path: "/workspaces/4679"}
      },
      claimed: MapSet.new([issue_id]),
      dispatch_recovery: %{workspace_ownership: %{waits: %{}, ready: %{}}, codex_thrash_budget: %{}}
    }

    {:noreply, after_down} = RetryEngine.handle_agent_down(state, ref, exit_reason)
    Map.fetch!(after_down.retry_attempts, issue_id)
  end
end
