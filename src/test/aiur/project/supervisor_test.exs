defmodule Aiur.Project.SupervisorTest do
  use ExUnit.Case, async: false

  alias Aiur.Orchestrator.Slots
  alias Aiur.Project
  alias Aiur.Project.{Context, StatusRows, Supervisors, Table, Watcher}
  alias Aiur.TestSupport.WorkflowFiles

  setup do
    root = Path.join(System.tmp_dir!(), "project-supervisor-#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    on_exit(fn -> Enum.each(["o/a", "o/b"], &Table.drop/1) end)
    me = self()
    start_supervised!(Supervisors)
    start_supervised!({Watcher, alert_fun: fn name, opts -> send(me, {:alert, name, opts[:message]}) end})
    {:ok, a: project("o/a", root, 3), b: project("o/b", root, 5)}
  end

  defp project(repo, root, max_agents) do
    state_root = Path.join(root, String.replace(repo, "/", "-"))
    config = Path.join([state_root, "repo", ".aiur", "config"])
    File.mkdir_p!(Path.dirname(config))
    WorkflowFiles.write_workflow_file!(config, tracker_kind: "memory", max_concurrent_agents: max_agents)
    Project.from_machine_entry(%{repo: repo, config: config}, state_root)
  end

  defp break_config(%Project{config_path: path}), do: WorkflowFiles.write_workflow_file_atomic!(path, "tracker: [unclosed\n")

  defp in_project(project, fun) do
    Task.async(fn ->
      Context.put(project)
      fun.()
    end)
    |> Task.await(10_000)
  end

  defp orchestrator(%Project{id: id}), do: GenServer.whereis(Project.name(Aiur.Orchestrator, id))

  test "two projects each run their own orchestrator on their own config", %{a: a, b: b} do
    assert {:ok, _} = Supervisors.start_project(a)
    assert {:ok, _} = Supervisors.start_project(b)

    assert [%{id: "o/a", state: :running}, %{id: "o/b", state: :running}] = Supervisors.which_projects()
    # Each orchestrator answers with its own project's config: it resolved the project from its root.
    assert %{max: 3} = in_project(a, &Slots.max_concurrent_agents/0)
    assert %{max: 5} = in_project(b, &Slots.max_concurrent_agents/0)
    assert [%{id: "o/a", state: "running"}, %{id: "o/b", state: "running"}] = StatusRows.rows()
  end

  test "a project whose config does not parse fails alone", %{a: a, b: b} do
    break_config(a)
    assert {:ok, _} = Supervisors.start_project(b)
    assert {:error, _} = Supervisors.start_project(a)

    assert_receive {:alert, "system.project.boot_failed", message}, 1_000
    assert message =~ "o/a"
    refute message =~ a.config_path
    assert is_pid(orchestrator(b))
    assert [%{id: "o/a", state: :failed}, %{id: "o/b", state: :running}] = Supervisors.which_projects()
    assert [%{id: "o/a", state: "failed", running: nil, freshness: "unavailable"}, %{id: "o/b"}] = StatusRows.rows()
  end

  test "a crash-looping project stops alone and the dynamic supervisor survives", %{a: a, b: b} do
    {:ok, a_root} = Supervisors.start_project(a)
    {:ok, _} = Supervisors.start_project(b)
    ref = Process.monitor(a_root)

    Enum.each(1..4, fn _ ->
      pid = wait_for(fn -> orchestrator(a) end)
      Process.exit(pid, :kill)
      wait_for(fn -> orchestrator(a) != pid or not Process.alive?(a_root) end)
    end)

    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    assert_receive {:alert, "system.project.boot_failed", message}, 1_000
    assert message =~ "o/a"
    assert Process.alive?(Process.whereis(Supervisors))
    assert is_pid(orchestrator(b))
    assert [%{id: "o/a", state: :failed}, %{id: "o/b", state: :running}] = Supervisors.which_projects()
  end

  test "reload stops only the removed project", %{a: a, b: b} do
    {:ok, a_root} = Supervisors.start_project(a)
    {:ok, b_root} = Supervisors.start_project(b)
    b_orchestrator = orchestrator(b)

    assert %{stopped: ["o/a"], unchanged: ["o/b"], started: [], failed: []} = Supervisors.reload([b])
    refute Process.alive?(a_root)
    assert Project.Registry.root_pid("o/b") == b_root
    assert orchestrator(b) == b_orchestrator
    refute_received {:alert, "system.project.boot_failed", _}
  end

  test "reload retries a failed project and resolves its alert", %{a: a, b: b} do
    break_config(a)
    {:error, _} = Supervisors.start_project(a)
    assert_receive {:alert, "system.project.boot_failed", _}, 1_000
    WorkflowFiles.write_workflow_file!(a.config_path, tracker_kind: "memory", max_concurrent_agents: 3)

    assert %{started: ["o/a", "o/b"], stopped: []} = Supervisors.reload([a, b])
    assert_receive {:alert, "system.project.boot_failed.resolved", message}, 1_000
    assert message =~ "o/a"
  end

  test "a task started by a project process works for that project", %{a: a} do
    {:ok, _} = Supervisors.start_project(a)
    {:ok, pid} = Agent.start(fn -> nil end, name: Project.name(:project_probe, "o/a"))
    on_exit(fn -> Process.exit(pid, :kill) end)

    assert Agent.get(pid, fn _ -> Task.async(fn -> Context.current_id() end) |> Task.await() end) == "o/a"
    assert Task.async(fn -> Context.current_id() end) |> Task.await() == nil
  end

  defp wait_for(fun, tries \\ 200) do
    case fun.() do
      falsy when falsy in [nil, false] and tries > 0 ->
        Process.sleep(10)
        wait_for(fun, tries - 1)

      value ->
        value
    end
  end
end
