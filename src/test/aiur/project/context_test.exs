defmodule Aiur.Project.ContextTest do
  use ExUnit.Case, async: true

  alias Aiur.Project
  alias Aiur.Project.Context

  defp project(repo), do: Project.from_machine_entry(%{repo: repo, config: "/x/config"}, "/x/state")

  test "from_machine_entry/2 case-folds the id and keeps the repo" do
    assert %Project{id: "o/repo", repo: "O/Repo", config_path: "/x/config", state_root: "/x/state"} = project("O/Repo")
  end

  test "put/current/delete round-trip, and no context is nil" do
    assert Context.current() == nil
    a = project("o/a")
    :ok = Context.put(a)
    assert Context.current() == a
    assert Context.current_id() == "o/a"
    :ok = Context.delete()
    assert Context.current_id() == nil
  end

  test "without/1 clears the context for the call and restores it" do
    a = project("o/a")
    Context.put(a)
    assert Context.without(fn -> Context.current() end) == nil
    assert Context.current() == a
  end

  test "Project.Task.async/1 hands the parent's project to the task" do
    a = project("o/a")
    Context.put(a)
    assert Aiur.Project.Task.async(fn -> Context.current() end) |> Task.await() == a
    assert Task.async(fn -> Context.current() end) |> Task.await() == nil
  end

  test "a machine process starts work for a project it holds only briefly" do
    b = project("o/b")
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        Context.put(b)
        seen = Aiur.Project.Task.async(fn -> Context.current() end) |> Task.await()
        Context.delete()
        send(parent, {:seen, seen, Context.current()})
      end)

    assert is_pid(pid)
    assert_receive {:seen, ^b, nil}, 1_000
  end
end
