defmodule Aiur.AgentRunner.RefreshFailureExitTest do
  # OGM tickets went `agent:error` within an hour with GitHub quota at 4678/5000:
  # the between-turn issue-state refresh hit a shared-budget hold or a transient
  # tracker fault, the runner raised on `{:issue_state_refresh_failed, _}`, and
  # each raise spent a failure attempt until retries were exhausted.
  use Aiur.TestSupport

  alias Aiur.AgentRunner
  alias Aiur.Orchestrator.{RetryEngine, State}

  @issue %Issue{id: "refresh-held", identifier: "MT-REFRESH", title: "Refresh held", state: "in-progress", labels: []}

  test "a budget hold on the issue-state refresh retries after the hold without spending an attempt" do
    hold = %{reason: :shared_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), 30, :second)}
    reason = {:issue_state_refresh_failed, {:github, :local_hold, %{reason: {:aiur, :locally_held, hold}, hold: hold}}}

    assert catch_exit(AgentRunner.handle_run_error(@issue, reason)) == reason

    ref = make_ref()
    attempt = Config.max_retry_attempts()

    state = %State{
      running: %{@issue.id => %{ref: ref, identifier: @issue.identifier, started_at: DateTime.utc_now(), retry_attempt: attempt}},
      claimed: MapSet.new([@issue.id]),
      dispatch_recovery: %{workspace_ownership: %{waits: %{}, ready: %{}}, codex_thrash_budget: %{}}
    }

    assert {:noreply, after_down} = RetryEngine.handle_agent_down(state, ref, reason)
    retry = after_down.retry_attempts[@issue.id]
    Process.cancel_timer(retry.timer_ref)
    assert retry.delay_type == :local_budget_hold
    assert retry.attempt == attempt
    assert retry.local_budget_hold == hold
    refute RetryEngine.failure_retry?(retry)
  end

  test "a transient tracker failure on the refresh ends the run cleanly instead of raising" do
    assert AgentRunner.handle_run_error(@issue, {:issue_state_refresh_failed, {:github, :timeout, %{}}}) == :ok
    assert AgentRunner.handle_run_error(@issue, {:issue_state_refresh_failed, {:github, :http, %{status: 502}}}) == :ok
  end

  test "a permanent refresh failure still raises a counted failure" do
    assert_raise RuntimeError, ~r/issue_state_refresh_failed/, fn ->
      AgentRunner.handle_run_error(@issue, {:issue_state_refresh_failed, {:github, :permission, %{}}})
    end
  end
end
