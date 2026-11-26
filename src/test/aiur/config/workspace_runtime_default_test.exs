defmodule Aiur.Config.WorkspaceRuntimeDefaultTest do
  use ExUnit.Case, async: false

  alias Aiur.Config.Schema

  # Guard against reintroducing the compile-time default fixed in #5426.
  @tag :tmp_dir
  test "workspace roots use runtime TMPDIR after the schema is loaded", %{tmp_dir: tmp_dir} do
    assert {:ok, _settings} = Schema.parse(%{})
    previous_tmpdir = System.get_env("TMPDIR")
    runtime_tmpdir = Path.expand(tmp_dir)

    try do
      System.put_env("TMPDIR", runtime_tmpdir)
      assert System.tmp_dir!() == runtime_tmpdir

      for config <- [%{}, %{"workspace" => %{}}, %{"workspace" => %{"root" => nil}}, %{"workspace" => %{"root" => ""}}] do
        assert {:ok, settings} = Schema.parse(config)
        assert settings.workspace.root == Path.join(runtime_tmpdir, "aiur_workspaces")
      end

      for root <- [Path.join(runtime_tmpdir, "explicit"), "relative/workspaces"] do
        assert {:ok, settings} = Schema.parse(%{"workspace" => %{"root" => root}})
        assert settings.workspace.root == root
      end
    after
      if previous_tmpdir, do: System.put_env("TMPDIR", previous_tmpdir), else: System.delete_env("TMPDIR")
    end
  end
end
