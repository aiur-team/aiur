defmodule Aiur.Core.OrchestratorLifecycleTest do
  use Aiur.TestSupport

  test "Aiur.start_link delegates to the orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:aiur, :memory_tracker_issues, [])
    orchestrator_pid = Process.whereis(Aiur.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(Aiur.Orchestrator)) do
        case Supervisor.restart_child(Aiur.Supervisor, Aiur.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Orchestrator)
    end

    assert {:ok, pid} = Aiur.start_link()
    assert Process.whereis(Aiur.Orchestrator) == pid

    GenServer.stop(pid)
  end

  test "two unnamed orchestrators start independently" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:aiur, :memory_tracker_issues, [])

    {:ok, first} = start_supervised({Orchestrator, initial_poll?: false}, id: :first_unnamed_orchestrator)
    {:ok, second} = start_supervised({Orchestrator, initial_poll?: false}, id: :second_unnamed_orchestrator)

    assert first != second
    assert :sys.get_state(first).snapshot_key != :sys.get_state(second).snapshot_key
  end

  test "an unnamed orchestrator accepts PID-targeted lifecycle and status APIs" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:aiur, :memory_tracker_issues, [])

    {:ok, orchestrator} = start_supervised({Orchestrator, initial_poll?: false}, id: :pid_targeted_orchestrator)

    assert %{queued: true, operations: ["poll", "reconcile"]} = Orchestrator.request_refresh(orchestrator)
    assert [] = Orchestrator.status(orchestrator, 1_000)
    assert {[], capacity} = Orchestrator.status_with_capacity(orchestrator, 1_000)
    assert is_map(capacity)
    assert is_map(Orchestrator.snapshot(orchestrator, 1_000))
    assert %{checking?: checking?} = Orchestrator.poll_status(orchestrator, 1_000)
    assert is_boolean(checking?)
    assert [] = Orchestrator.list_active_identifiers(orchestrator, 1_000)
    assert [] = Orchestrator.list_running_active_identifiers(orchestrator, 1_000)
  end

  test "unregistered global and via orchestrator names are unavailable" do
    registry_name = Module.concat(__MODULE__, PidTargetedOrchestratorRegistry)
    start_supervised!({Registry, keys: :unique, name: registry_name})

    unavailable_servers = [
      {:global, {__MODULE__, :missing_orchestrator}},
      {:via, Registry, {registry_name, :missing_orchestrator}}
    ]

    for server <- unavailable_servers do
      assert :unavailable = Orchestrator.request_refresh(server)
      assert :unavailable = Orchestrator.status(server, 1_000)
      assert :unavailable = Orchestrator.snapshot(server, 1_000)
      assert [] = Orchestrator.list_active_identifiers(server, 1_000)
      assert [] = Orchestrator.list_running_active_identifiers(server, 1_000)
    end
  end

  test "registered global and via orchestrator names accept lifecycle and status APIs" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:aiur, :memory_tracker_issues, [])

    registry_name = Module.concat(__MODULE__, LivePidTargetedOrchestratorRegistry)
    start_supervised!({Registry, keys: :unique, name: registry_name})

    global_name = {:global, {__MODULE__, :global_orchestrator}}
    via_name = {:via, Registry, {registry_name, :via_orchestrator}}

    {:ok, _} = start_supervised({Orchestrator, [name: global_name, initial_poll?: false]}, id: :global_targeted_orchestrator)
    {:ok, _} = start_supervised({Orchestrator, [name: via_name, initial_poll?: false]}, id: :via_targeted_orchestrator)

    for server <- [global_name, via_name] do
      assert %{queued: true, operations: ["poll", "reconcile"]} = Orchestrator.request_refresh(server)
      assert [] = Orchestrator.status(server, 1_000)
      assert is_map(Orchestrator.snapshot(server, 1_000))
      assert [] = Orchestrator.list_active_identifiers(server, 1_000)
      assert [] = Orchestrator.list_running_active_identifiers(server, 1_000)
    end
  end

  test "a stopped unnamed orchestrator is unavailable to lifecycle and status APIs" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:aiur, :memory_tracker_issues, [])

    {:ok, orchestrator} = start_supervised({Orchestrator, initial_poll?: false}, id: :stopped_pid_targeted_orchestrator)
    :ok = GenServer.stop(orchestrator)

    assert :unavailable = Orchestrator.request_refresh(orchestrator)
    assert :unavailable = Orchestrator.status(orchestrator, 1_000)
    assert :unavailable = Orchestrator.snapshot(orchestrator, 1_000)
    assert [] = Orchestrator.list_active_identifiers(orchestrator, 1_000)
    assert [] = Orchestrator.list_running_active_identifiers(orchestrator, 1_000)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end
end
