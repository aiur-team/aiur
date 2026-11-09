defmodule Aiur.Project.RegistryTest do
  use ExUnit.Case, async: false

  alias Aiur.Project.Registry, as: ProjectRegistry

  test "a dead root is not listed while the Registry has yet to unregister it" do
    project = %Aiur.Project{id: "o/registry-dead-root", repo: "o/registry-dead-root", config_path: "/nonexistent/config", state_root: "/nonexistent"}
    me = self()

    root =
      start_supervised!(
        {Task,
         fn ->
           {:ok, _} = ProjectRegistry.register_root(project)
           send(me, :registered)
           receive do: (:never -> :ok)
         end}
      )

    assert_receive :registered, 1_000
    assert ProjectRegistry.root_pid(project.id) == root

    # Hold the partitions so the Registry cannot process the root's exit: the window the race lives in.
    partitions = for {_, pid, _, _} <- Supervisor.which_children(Aiur.ProjectRegistry), is_pid(pid), do: pid
    Enum.each(partitions, &:sys.suspend/1)
    on_exit(fn -> Enum.each(partitions, &:sys.resume/1) end)

    ref = Process.monitor(root)
    Process.exit(root, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}, 1_000

    refute project.id in ProjectRegistry.project_ids()
    assert ProjectRegistry.root_pid(project.id) == nil
    assert ProjectRegistry.project(project.id) == nil
  end
end
