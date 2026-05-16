defmodule SymphonyElixir.AlertsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentLog, Alerts, Orchestrator}

  test "emit_system writes a structured alert entry and selects a configured sound" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-alerts-#{System.unique_integer([:positive])}")

    workspace = Path.join(workspace_root, "MT-ALERT-1")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert :ok =
             Alerts.emit_system("task.done",
               issue: "MT-ALERT-1",
               player: fn sound -> send(self(), {:played_sound, sound}) end,
               terminal_notifier: fn -> send(self(), :terminal_notified) end
             )

    assert_receive {:played_sound, played_sound}
    assert played_sound == Path.join(System.user_home!(), "alerts/advisor-upgrade-complete.wav")
    assert_receive :terminal_notified

    log_path = Path.join(workspace, "logs/agent.md")
    ndjson_path = Path.join(workspace, "logs/agent.ndjson")

    assert File.read!(ndjson_path) =~ "\"name\":\"task.done\""
    assert File.read!(ndjson_path) =~ "\"message\":\"Task completed\""

    assert [%{role: "alert", title: "task.done", body: "Task completed"}] =
             log_path
             |> AgentLog.read()
             |> AgentLog.parse()
  end

  test "emit_custom rejects reserved system scopes" do
    assert {:error, :system_scope_reserved} =
             Alerts.emit_custom("task.done", "Task done", "Completed")
  end

  test "task state transitions emit task alerts into the issue workspace log" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-alert-state-#{System.unique_integer([:positive])}")

    workspace = Path.join(workspace_root, "MT-ALERT-2")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    previous_issue = %Issue{id: "issue-1", identifier: "MT-ALERT-2", state: "Todo", title: "Task"}
    next_issue = %Issue{id: "issue-1", identifier: "MT-ALERT-2", state: "In Progress", title: "Task"}

    state = %Orchestrator.State{last_polled_issues: %{"issue-1" => previous_issue}}

    _updated_state = Orchestrator.sync_polled_issue_state_for_test(state, [next_issue])

    assert Path.join(workspace, "logs/agent.ndjson") |> File.read!() =~ "\"name\":\"task.in-progress\""
  end

  test "todo overload emits task.todo.more_agents once per overload interval" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-alert-overload-#{System.unique_integer([:positive])}")

    workspace = Path.join(workspace_root, "MT-ALERT-3")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      max_concurrent_agents: 1
    )

    issues = [
      %Issue{id: "issue-1", identifier: "MT-ALERT-3", state: "Todo", title: "First"},
      %Issue{id: "issue-2", identifier: "MT-ALERT-4", state: "Todo", title: "Second"}
    ]

    state = %Orchestrator.State{}
    state = Orchestrator.sync_todo_capacity_alert_for_test(state, issues)
    _state = Orchestrator.sync_todo_capacity_alert_for_test(state, issues)

    log = Path.join(workspace, "logs/agent.ndjson") |> File.read!()
    assert String.split(log, "\"name\":\"task.todo.more_agents\"") |> length() == 2
  end

  test "agent paused and unpaused alerts fire from control-state transitions" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-alert-pause-#{System.unique_integer([:positive])}")

    workspace = Path.join(workspace_root, "MT-ALERT-5")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    orchestrator_name = Module.concat(__MODULE__, :PauseAlertOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{
            "issue-5" => %{
              pid: self(),
              ref: nil,
              identifier: "MT-ALERT-5",
              issue: %Issue{id: "issue-5", identifier: "MT-ALERT-5", state: "In Progress", title: "Pause"},
              workspace_path: workspace,
              worker_host: nil,
              control: %{can_interrupt: true, safe_checkpoints: [], status: :working},
              started_at: DateTime.utc_now()
            }
          }
      }
    end)

    log_path = Path.join(workspace, "logs/agent.ndjson")

    assert_eventually(
      fn ->
        send(pid, {:worker_control_state, "issue-5", :paused})
        Process.sleep(25)
        send(pid, {:worker_control_state, "issue-5", :working})
        log = File.read!(log_path)

        String.contains?(log, "\"name\":\"agent.paused\"") and
          String.contains?(log, "\"name\":\"agent.unpaused\"")
      end,
      20
    )
  end

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition was not met in time")
end
