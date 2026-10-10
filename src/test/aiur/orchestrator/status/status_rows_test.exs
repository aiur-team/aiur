defmodule Aiur.Orchestrator.Status.StatusRowsTest do
  use Aiur.TestSupport

  import Aiur.OrchestratorStatusSupport

  test "snapshot renders an issue's pending operator messages without crashing" do
    orchestrator_name = Module.concat(__MODULE__, :PendingOperatorMsgOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    {store, _item} =
      Aiur.AgentQueueStore.enqueue(
        Aiur.AgentQueueStore.new(),
        Aiur.AgentQueue.operator_message("MT-OP", "hello operator text")
      )

    entry =
      "issue-op"
      |> running_entry("MT-OP", :working)
      |> Map.merge(%{
        codex_app_server_pid: nil,
        last_codex_timestamp: nil,
        last_codex_message: nil,
        last_codex_event: nil
      })

    :sys.replace_state(pid, fn state ->
      %{state | queue_store: store, running: %{"issue-op" => entry}}
    end)

    snapshot = Orchestrator.snapshot(orchestrator_name, 5_000)

    # Regression: rendering the visible operator message used to run get_in/2 on
    # an %AgentQueueItem{} struct, which crashed the whole Orchestrator GenServer
    # (structs don't implement Access). The struct's body map is reached directly now.
    refute snapshot == :timeout
    assert Process.alive?(pid)
    assert inspect(snapshot) =~ "hello operator text"
  end

  test "snapshot keeps legacy running entries with omitted optional Codex fields available" do
    orchestrator_name = Module.concat(__MODULE__, :LegacySnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    legacy_entry =
      running_entry("issue-legacy", "MT-LEGACY", :working)
      |> Map.drop([
        :session_id,
        :codex_app_server_pid,
        :agent_input_tokens,
        :agent_output_tokens,
        :agent_total_tokens,
        :last_codex_timestamp,
        :last_codex_message,
        :last_codex_event,
        :started_at
      ])

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"issue-legacy" => legacy_entry}}
    end)

    assert %{running: [snapshot_entry]} = Orchestrator.snapshot(orchestrator_name, 5_000)
    assert snapshot_entry.identifier == "MT-LEGACY"
    assert snapshot_entry.session_id == nil
    assert snapshot_entry.codex_app_server_pid == nil
    assert snapshot_entry.runtime_seconds == 0
  end

  test "session max status counts active agents separately from paused agents" do
    orchestrator_name = Module.concat(__MODULE__, :SessionMaxStatusOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | session_max_concurrent_agents: 2,
          running: %{
            "issue-active" => running_entry("issue-active", "MT-ACTIVE", :working),
            "issue-paused" => running_entry("issue-paused", "MT-PAUSED", :paused)
          }
      }
    end)

    assert %{
             active: 1,
             paused: 1,
             configured: 10,
             max: 2,
             session_override?: true,
             draining?: false
           } = Orchestrator.max_concurrent_agents(orchestrator_name)

    assert {:ok, %{max: 1, active: 1, paused: 1, session_override?: true, draining?: false}} =
             Orchestrator.adjust_max_concurrent_agents(orchestrator_name, -1)
  end

  test "session max can be decreased below current active agents to drain" do
    orchestrator_name = Module.concat(__MODULE__, :SessionMaxDrainOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | session_max_concurrent_agents: 2,
          running: %{
            "issue-a" => running_entry("issue-a", "MT-A", :working),
            "issue-b" => running_entry("issue-b", "MT-B", :working)
          }
      }
    end)

    assert {:ok, %{max: 1, active: 2, draining?: true}} =
             Orchestrator.adjust_max_concurrent_agents(orchestrator_name, -1)

    assert %{max: 1, active: 2, draining?: true} =
             Orchestrator.max_concurrent_agents(orchestrator_name)
  end

  test "status returns running paused and idle agents" do
    orchestrator_name = Module.concat(__MODULE__, :AgentStatusOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | last_polled_issues: %{
            "issue-active" => %Issue{id: "issue-active", identifier: "repo#44", state: "In Progress", title: "Active"},
            "issue-paused" => %Issue{id: "issue-paused", identifier: "repo#45", state: "In Progress", title: "Paused"},
            "issue-idle" => %Issue{id: "issue-idle", identifier: "repo#46", state: "Todo", title: "Idle"}
          },
          running: %{
            "issue-active" => running_entry("issue-active", "repo#44", :working, self(), nil, "Active"),
            "issue-paused" => running_entry("issue-paused", "repo#45", :paused, self(), nil, "Paused")
          }
      }
    end)

    assert [
             %{identifier: "repo#44", state: :running, title: "Active"},
             %{identifier: "repo#45", state: :paused, title: "Paused"},
             %{identifier: "repo#46", state: :idle, title: "Idle"}
           ] = Orchestrator.status(orchestrator_name, 5_000)
  end

  test "status keeps cached and deactivated rows for control commands" do
    orchestrator_name = Module.concat(__MODULE__, :AgentStatusClosedOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    deactivated =
      "issue-deactivated"
      |> running_entry("repo#491", :deactivated, self(), nil, "Deactivated")

    closed_running =
      "issue-closed-running"
      |> running_entry("repo#492", :working, self(), nil, "Closed running")
      |> update_in([:issue], &%{&1 | state: "Closed"})

    :sys.replace_state(pid, fn state ->
      %{
        state
        | last_polled_issues: %{
            "issue-active" => %Issue{id: "issue-active", identifier: "repo#44", state: "In Progress", title: "Active"},
            "issue-closed-stale-label" => %Issue{
              id: "issue-closed-stale-label",
              identifier: "repo#523",
              state: "Closed",
              title: "Closed stale active label",
              labels: ["agent:human-review"]
            },
            "issue-unlabeled" => %Issue{
              id: "issue-unlabeled",
              identifier: "repo#524",
              state: nil,
              title: "Closed with active label removed"
            }
          },
          running: %{
            "issue-active" => running_entry("issue-active", "repo#44", :working, self(), nil, "Active"),
            "issue-deactivated" => deactivated,
            "issue-closed-running" => closed_running
          }
      }
    end)

    assert [
             %{identifier: "repo#44", state: :running, title: "Active", work_state: :working},
             %{identifier: "repo#491", state: :running, title: "Deactivated", work_state: :deactivated},
             %{identifier: "repo#492", state: :running, title: "Closed running", tracker_state: "Closed"},
             %{identifier: "repo#523", state: :idle, title: "Closed stale active label", tracker_state: "Closed"},
             %{identifier: "repo#524", state: :idle, title: "Closed with active label removed", tracker_state: nil}
           ] = Orchestrator.status(orchestrator_name, 5_000)
  end
end
