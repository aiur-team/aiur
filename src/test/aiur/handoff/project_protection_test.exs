defmodule Aiur.Handoff.ProjectProtectionTest do
  use ExUnit.Case, async: false

  alias Aiur.Handoff.Protection
  alias Aiur.Project.Context

  defp project(id), do: %Aiur.Project{id: id, repo: id, config_path: "/nonexistent/#{id}", state_root: "/nonexistent/#{id}"}

  defp in_project(id, fun) do
    Task.async(fn ->
      Context.put(project(id))
      fun.()
    end)
    |> Task.await()
  end

  setup do
    on_exit(fn -> Enum.each(["o/a", "o/b"], fn id -> in_project(id, &Protection.reset/0) end) end)
  end

  test "protection is per project: the same ticket number is protected only where it was prepared" do
    in_project("o/a", fn -> Protection.store(self(), %{handoff_id: "h"}, MapSet.new(["12"]), [], 60_000) end)

    assert in_project("o/a", fn -> Protection.protected?("12") end)
    refute in_project("o/b", fn -> Protection.protected?("12") end)
    assert Protection.active?()
    assert Protection.protected_anywhere?("12")
    assert [%{result: %{handoff_id: "h"}}] = Protection.prepared_all()

    in_project("o/b", &Protection.reset/0)
    assert in_project("o/a", fn -> Protection.protected?("12") end), "resetting B must not drop A's protection"

    in_project("o/a", &Protection.reset/0)
    assert Protection.prepared_all() == []
  end
end
