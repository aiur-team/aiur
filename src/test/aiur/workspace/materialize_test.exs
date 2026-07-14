defmodule Aiur.Workspace.MaterializeTest do
  use ExUnit.Case, async: true

  alias Aiur.Workspace.Materialize

  setup do
    tmp = Path.join(System.tmp_dir!(), "aiur_mat_#{System.unique_integer([:positive])}")
    base = Path.join(tmp, "base")
    File.mkdir_p!(base)

    System.cmd("git", ["init", "--quiet", "-b", "main", base])
    System.cmd("git", ["-C", base, "config", "user.email", "t@example.com"])
    System.cmd("git", ["-C", base, "config", "user.name", "T"])
    File.write!(Path.join(base, "README.md"), "v1\n")
    System.cmd("git", ["-C", base, "add", "."])
    System.cmd("git", ["-C", base, "commit", "--quiet", "-m", "init"])

    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp, base: base}
  end

  test "materialize_from_base/2 with non-existent base returns error and workspace does not exist", %{tmp: tmp} do
    workspace = Path.join(tmp, "ws1")
    base_missing = Path.join(tmp, "no_such_base")

    assert {:error, _} = Materialize.materialize_from_base(base_missing, workspace)
    refute File.exists?(workspace)
  end

  test "materialize_from_base/2 into a workspace whose parent dir does not exist succeeds", %{tmp: tmp, base: base} do
    # parent dir "nested/subdir" does not exist yet
    workspace = Path.join(tmp, "nested/subdir/ws1")
    refute File.exists?(Path.dirname(workspace))

    assert :ok = Materialize.materialize_from_base(base, workspace)
    assert File.dir?(workspace)
    assert File.exists?(Path.join(workspace, "README.md"))
  end

  test "materialize_from_base/3 with non-existent base returns error and cleans up workspace", %{tmp: tmp} do
    workspace = Path.join(tmp, "ws3")
    base_missing = Path.join(tmp, "no_such_base")

    assert {:error, _} = Materialize.materialize_from_base(base_missing, workspace, "my-branch")
    refute File.exists?(workspace)
  end

  test "materialize_from_base/3 with valid base creates workspace on the pr branch", %{tmp: tmp, base: base} do
    workspace = Path.join(tmp, "ws4")

    assert :ok = Materialize.materialize_from_base(base, workspace, "my-pr-branch")
    assert File.dir?(workspace)
    assert File.exists?(Path.join(workspace, "README.md"))
  end

  test "materialization atomically replaces a logs-only workspace without losing the event stream", %{
    tmp: tmp,
    base: base
  } do
    workspace = Path.join(tmp, "logs-only")
    log_path = Path.join([workspace, "logs", "agent.ndjson"])
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, "{\"event\":\"alert\"}\n")

    assert :ok = Materialize.materialize_from_base(base, workspace)

    assert File.exists?(Path.join(workspace, "README.md"))
    assert File.read!(log_path) == "{\"event\":\"alert\"}\n"
  end
end
