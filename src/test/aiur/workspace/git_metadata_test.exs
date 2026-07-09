defmodule Aiur.Workspace.GitMetadataTest do
  use ExUnit.Case, async: true

  alias Aiur.Workspace.{Checkout, GitMetadata}

  setup do
    tmp = Path.join(System.tmp_dir!(), "aiur-git-metadata-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "ensure_git_metadata_writable removes a stale index lock", %{tmp: tmp} do
    repo = init_repo!(Path.join(tmp, "repo"))
    lock = Path.join([repo, ".git", "index.lock"])
    File.write!(lock, "stale\n")

    assert :ok = GitMetadata.ensure_git_metadata_writable(repo)
    refute File.exists?(lock)
  end

  test "ensure_git_metadata_writable returns ok for a non git directory", %{tmp: tmp} do
    non_git = Path.join(tmp, "non-git")
    File.mkdir_p!(non_git)

    assert :ok = GitMetadata.ensure_git_metadata_writable(non_git)
  end

  test "ensure_git_metadata_writable removes a pr anchored remote ref lock", %{tmp: tmp} do
    repo = init_repo!(Path.join(tmp, "pr-77"))
    assert :ok = Checkout.checkout_existing_pr_branch(repo, "feature/login")

    lock = Path.join([repo, ".git", "refs", "remotes", "origin", "feature", "login.lock"])
    File.mkdir_p!(Path.dirname(lock))
    File.write!(lock, "stale\n")

    assert :ok = GitMetadata.ensure_git_metadata_writable(repo)
    refute File.exists?(lock)
  end

  test "ensure_git_metadata_writable rejects git dirs outside the workspace", %{tmp: tmp} do
    workspace = Path.join(tmp, "workspace")
    git_dir = Path.join(tmp, "outside.git")

    File.mkdir_p!(workspace)
    git!(["init", "--quiet", "--separate-git-dir", git_dir, "-b", "main", workspace])

    assert {:error, {:workspace_git_metadata_unwritable, ^workspace, {:git_dir_outside_workspace, outside_git_dir}}} =
             GitMetadata.ensure_git_metadata_writable(workspace)

    assert outside_git_dir == Path.expand(git_dir)
  end

  defp init_repo!(repo) do
    File.mkdir_p!(repo)
    git!(["init", "--quiet", "-b", "main", repo])
    git!(["-C", repo, "config", "user.email", "t@example.com"])
    git!(["-C", repo, "config", "user.name", "T"])
    File.write!(Path.join(repo, "README.md"), "initial\n")
    git!(["-C", repo, "add", "."])
    git!(["-C", repo, "commit", "--quiet", "-m", "initial"])
    repo
  end

  defp git!(args) do
    {out, 0} = System.cmd("git", args, stderr_to_stdout: true)
    out
  end
end
