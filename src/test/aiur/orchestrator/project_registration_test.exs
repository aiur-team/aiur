defmodule Aiur.Orchestrator.ProjectRegistrationTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.Slots
  alias Aiur.Project
  alias Aiur.Project.Context

  defp project(repo), do: Project.from_machine_entry(%{repo: repo, config: "/x/config"}, "/x/state")

  defp start_orchestrator(%Project{id: id}) do
    {:ok, pid} = Aiur.Orchestrator.start_link(name: Project.name(Aiur.Orchestrator, id), initial_poll?: false)
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

  test "a caller with no project does not reach a project orchestrator" do
    start_orchestrator(project("o/a"))
    assert Project.whereis(Aiur.Orchestrator) == Aiur.Orchestrator
    assert GenServer.whereis(Project.whereis(Aiur.Orchestrator, "o/a")) |> is_pid()
  end
end
