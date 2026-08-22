defmodule Aiur.Workspace.GitMetadataTest do
  use ExUnit.Case, async: true

  alias Aiur.Workspace.{Checkout, GitMetadata}

  setup do
    tmp = Path.join(System.tmp_dir!(), "aiur-git-metadata-#{System.pid()}-#{System.unique_integer([:positive])}")
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

  test "ensure_agent_logs_excluded preserves local excludes and ignores logs idempotently", %{tmp: tmp} do
    repo = init_repo!(Path.join(tmp, "repo"))
    gitignore = Path.join(repo, ".gitignore")
    exclude = Path.join([repo, ".git", "info", "exclude"])

    File.write!(gitignore, "tracked-ignore/\n")
    File.write!(exclude, "# existing local exclude")

    assert :ok = GitMetadata.ensure_agent_logs_excluded(repo)
    assert :ok = GitMetadata.ensure_agent_logs_excluded(repo)

    assert File.read!(gitignore) == "tracked-ignore/\n"
    assert File.read!(exclude) == "# existing local exclude\nlogs/\n.aiur-runtime/\n"

    File.mkdir_p!(Path.join(repo, "logs"))
    File.write!(Path.join([repo, "logs", "agent.md"]), "agent log\n")

    assert String.trim(git!(["-C", repo, "status", "--short", "--", "logs"])) == ""
  end

  test "ensure_tool_results_excluded makes runtime artifacts locally ignored", %{tmp: tmp} do
    repo = init_repo!(Path.join(tmp, "repo"))
    artifact = Path.join([repo, ".aiur-runtime", "tool-results", "result.json"])

    assert :ok = GitMetadata.ensure_tool_results_excluded(repo)
    File.mkdir_p!(Path.dirname(artifact))
    File.write!(artifact, "{}")

    assert {_output, 0} = System.cmd("git", ["-C", repo, "check-ignore", "-q", artifact])
  end

  test "ensure_tool_results_excluded rejects a symlinked git info directory", %{tmp: tmp} do
    repo = init_repo!(Path.join(tmp, "repo"))
    outside = Path.join(tmp, "outside-info")
    info = Path.join([repo, ".git", "info"])
    File.mkdir_p!(outside)
    File.rm_rf!(info)
    File.ln_s!(outside, info)

    assert {:error, {:workspace_git_metadata_unwritable, ^repo, {:symlinked_git_info, ^info}}} =
             GitMetadata.ensure_tool_results_excluded(repo)

    assert File.ls!(outside) == []
  end

  test "ensure_tool_results_excluded rejects a symlinked exclude file", %{tmp: tmp} do
    repo = init_repo!(Path.join(tmp, "repo"))
    exclude = Path.join([repo, ".git", "info", "exclude"])
    outside = Path.join(tmp, "outside-exclude")
    original = "do not change\n"
    File.write!(outside, original)
    File.rm!(exclude)
    File.ln_s!(outside, exclude)

    assert {:error, {:workspace_git_metadata_unwritable, ^repo, {:symlinked_git_exclude, ^exclude}}} =
             GitMetadata.ensure_tool_results_excluded(repo)

    assert File.read!(outside) == original
  end

  test "ensure_git_metadata_writable removes a readable ticket remote-ref lock", %{tmp: tmp} do
    repo = init_repo!(Path.join(tmp, "repo"))
    branch = "aiur/123-add-new-test-cases"
    assert :ok = Checkout.checkout_fresh_branch(repo, branch)

    lock = Path.join([repo, ".git", "refs", "remotes", "origin", "aiur", "123-add-new-test-cases.lock"])
    File.mkdir_p!(Path.dirname(lock))
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
