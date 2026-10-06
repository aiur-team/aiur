defmodule Aiur.AgentRunner.BudgetHoldExitTest do
  use Aiur.TestSupport

  alias Aiur.AgentRunner
  alias Aiur.Orchestrator.{RetryEngine, State}

  test "held preflight through run schedules a reset_at retry without consuming an attempt" do
    root = Aiur.TestSupport.tmp_root!("runner-budget-hold")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo", workspace_root: root, hook_after_create: "git -C \"$PWD\" init -q")
    hold = %{reason: :actor_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), 30, :second)}
    diagnostic = {:github_auth_preflight_failed, %{classification: :local_hold, detail: %{hold: hold}}}
    parent = self()
    previous = for key <- [:workspace_github_preflight_enabled, :workspace_github_preflight_fun], do: {key, Application.get_env(:aiur, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value), do: Application.delete_env(:aiur, key), else: Application.put_env(:aiur, key, value)
      end

      File.rm_rf!(root)
    end)

    Application.put_env(:aiur, :workspace_github_preflight_enabled, true)

    Application.put_env(:aiur, :workspace_github_preflight_fun, fn workspace ->
      send(parent, {:preflight, workspace})
      {:error, diagnostic}
    end)

    issue = %Issue{id: "held-run", identifier: "MT-HELD-RUN", title: "Held preflight", state: "todo", labels: []}
    {pid, ref} = spawn_monitor(fn -> AgentRunner.run(issue, nil, []) end)
    receive_barrier({:DOWN, ^ref, :process, ^pid, reason})
    assert {:workspace_github_connectivity_failed, workspace, ^diagnostic} = reason
    assert_received {:preflight, ^workspace}

    attempt = Config.max_retry_attempts()

    state = %State{
      running: %{issue.id => %{ref: ref, identifier: issue.identifier, started_at: DateTime.utc_now(), retry_attempt: attempt, workspace_path: workspace}},
      claimed: MapSet.new([issue.id]),
      dispatch_recovery: %{workspace_ownership: %{waits: %{}, ready: %{}}, codex_thrash_budget: %{}}
    }

    expected_due = System.monotonic_time(:millisecond) + DateTime.diff(hold.reset_at, DateTime.utc_now(), :millisecond)
    assert {:noreply, after_down} = RetryEngine.handle_agent_down(state, ref, reason)
    retry = after_down.retry_attempts[issue.id]
    Process.cancel_timer(retry.timer_ref)
    assert retry.delay_type == :local_budget_hold
    assert retry.attempt == attempt
    assert retry.local_budget_hold == hold
    assert_in_delta retry.due_at_ms, expected_due, 100
    refute RetryEngine.failure_retry?(retry)
  end

  test "permanent failure retains the ordinary exception contract" do
    assert_raise RuntimeError, "permission denied", fn ->
      AgentRunner.fail_run({:github, :permission, %{}}, "permission denied")
    end
  end
end
