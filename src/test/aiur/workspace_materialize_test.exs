defmodule Aiur.WorkspaceMaterializeTest do
  use ExUnit.Case, async: true

  alias Aiur.Workspace

  setup do
    tmp = Path.join(System.tmp_dir!(), "aiur_ws_#{System.unique_integer([:positive])}")
    base = Path.join(tmp, "base")
    File.mkdir_p!(base)

    git!(["init", "--quiet", "-b", "main", base])
    git!(["-C", base, "config", "user.email", "t@example.com"])
    git!(["-C", base, "config", "user.name", "T"])
    File.write!(Path.join(base, "README.md"), "v1\n")
    File.write!(Path.join(base, ".gitignore"), "_build/\n")
    git!(["-C", base, "add", "."])
    git!(["-C", base, "commit", "--quiet", "-m", "init"])

    # Warm build artifacts: gitignored, present in the working tree — these are
    # exactly what the copy must carry so the agent skips the recompile.
    File.mkdir_p!(Path.join(base, "_build"))
    File.write!(Path.join(base, "_build/sentinel"), "warm\n")

    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp, base: base}
  end

  test "copies the warm base (incl. gitignored _build) and branches aiur/<id>", %{tmp: tmp, base: base} do
    workspace = Path.join(tmp, "123")

    assert :ok = Workspace.materialize_from_base(base, workspace)

    assert File.read!(Path.join(workspace, "README.md")) == "v1\n"
    assert File.exists?(Path.join(workspace, "_build/sentinel")), "warm _build artifacts were not carried"
    assert branch(workspace) == "aiur/123"
  end

  test "materialized workspaces expose writable git metadata and repair stale locks", %{tmp: tmp, base: base} do
    workspace = Path.join(tmp, "561")

    assert :ok = Workspace.materialize_from_base(base, workspace)

    stale_locks = [
      Path.join([workspace, ".git", "index.lock"]),
      Path.join([workspace, ".git", "FETCH_HEAD.lock"]),
      Path.join([workspace, ".git", "ORIG_HEAD.lock"]),
      Path.join([workspace, ".git", "refs", "remotes", "origin", "aiur", "561.lock"])
    ]

    Enum.each(stale_locks, fn lock ->
      File.mkdir_p!(Path.dirname(lock))
      File.write!(lock, "stale\n")
    end)

    assert :ok = Workspace.ensure_git_metadata_writable(workspace)
    assert Enum.all?(stale_locks, &(not File.exists?(&1)))
  end

  test "returns an error (cold-clone fallback) when the base is not copyable", %{tmp: tmp} do
    assert {:error, _} =
             Workspace.materialize_from_base(Path.join(tmp, "nope"), Path.join(tmp, "ws"))
  end

  defp git!(args) do
    {out, 0} = System.cmd("git", args, stderr_to_stdout: true)
    out
  end

  defp branch(workspace) do
    {out, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "--abbrev-ref", "HEAD"], stderr_to_stdout: true)
    String.trim(out)
  end
end
