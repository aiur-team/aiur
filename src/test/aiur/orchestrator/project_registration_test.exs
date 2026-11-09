defmodule Aiur.Orchestrator.ProjectRegistrationTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.Client
  alias Aiur.Orchestrator.GlobalPause
  alias Aiur.Orchestrator.Slots
  alias Aiur.Project
  alias Aiur.Project.Context

  # The orchestrator adopts its project, so each project needs a readable config.
  defp project(repo, max_agents \\ 10) do
    dir = Path.join(System.tmp_dir!(), "project-registration-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    path = Path.join(dir, "config.yaml")
    write_workflow_file!(path, tracker_kind: "github", tracker_repo: repo, max_concurrent_agents: max_agents)
    Project.from_machine_entry(%{repo: repo, config: path}, dir)
  end

  # Started from inside the project, as its supervisor will: start_link carries the context.
  defp start_orchestrator(%Project{} = project) do
    pid =
      in_project(project, fn ->
        {:ok, pid} = Aiur.Orchestrator.start_link(name: Project.via(Aiur.Orchestrator), initial_poll?: false)
        Process.unlink(pid)
        pid
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp in_project(project, fun) do
    Task.async(fn ->
      Context.put(project)
      fun.()
    end)
    |> Task.await()
  end

  test "no context resolves to the legacy atom" do
    assert Project.whereis(Aiur.Orchestrator) == Aiur.Orchestrator
  end

  test "an explicit id is downcased into the registry key" do
    assert Project.whereis(Aiur.Orchestrator, "O/B") == {:via, Registry, {Aiur.ProjectRegistry, {"o/b", Aiur.Orchestrator}}}
  end

  test "two project trees in one VM each reach their own orchestrator" do
    {a, b} = {project("o/a"), project("o/b")}
    start_orchestrator(a)
    start_orchestrator(b)

    assert {:via, Registry, {Aiur.ProjectRegistry, {"o/a", Aiur.Orchestrator}}} = in_project(a, fn -> Project.whereis(Aiur.Orchestrator) end)

    {:ok, _} = in_project(a, fn -> Slots.set_max_concurrent_agents(7) end)

    assert %{max: 7} = in_project(a, &Slots.max_concurrent_agents/0)
    refute match?(%{max: 7}, in_project(b, &Slots.max_concurrent_agents/0))
  end

  test "Client.snapshot/0 from each project's process returns that project's snapshot" do
    {a, b} = {project("o/a", 3), project("o/b", 5)}
    start_orchestrator(a)
    start_orchestrator(b)

    assert %{capacity: %{max: 3}} = in_project(a, &Client.snapshot/0)
    assert %{capacity: %{max: 5}} = in_project(b, &Client.snapshot/0)
  end

  test "a default orchestrator argument follows the caller's project" do
    a = project("o/a")
    start_orchestrator(a)

    assert {:ok, %{}} = in_project(a, fn -> GlobalPause.sync_fleet_pause() end)
    # A project with no orchestrator must not fall through to the legacy one.
    assert {:error, :orchestrator_unavailable} = in_project(project("o/none"), fn -> GlobalPause.sync_fleet_pause() end)
  end

  test "a caller with no project does not reach a project orchestrator" do
    start_orchestrator(project("o/a"))
    assert Project.whereis(Aiur.Orchestrator) == Aiur.Orchestrator
    assert GenServer.whereis(Project.whereis(Aiur.Orchestrator, "o/a")) |> is_pid()
  end
end
