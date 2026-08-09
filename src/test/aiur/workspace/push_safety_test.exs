defmodule Aiur.Workspace.PushSafetyTest do
  use ExUnit.Case, async: true

  alias Aiur.Workspace.PushSafety

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-push-safety-#{System.unique_integer([:positive])}")
    remote = Path.join(root, "remote.git")
    repo = Path.join(root, "repo")
    File.mkdir_p!(root)
    git!(["init", "--quiet", "--bare", remote])
    git!(["init", "--quiet", "-b", "develop", repo])
    git!(["-C", repo, "config", "user.email", "t@example.com"])
    git!(["-C", repo, "config", "user.name", "T"])
    File.write!(Path.join(repo, "README.md"), "initial\n")
    git!(["-C", repo, "add", "README.md"])
    git!(["-C", repo, "commit", "--quiet", "-m", "initial"])
    git!(["-C", repo, "remote", "add", "origin", remote])
    git!(["-C", repo, "push", "--quiet", "-u", "origin", "develop"])

    on_exit(fn -> File.rm_rf!(root) end)
    %{repo: repo, remote: remote}
  end

  test "rejects a branch whose fork is too far behind the configured base", %{repo: repo} do
    git!(["-C", repo, "branch", "ticket"])
    add_base_files!(repo, 2)
    git!(["-C", repo, "push", "--quiet", "origin", "develop"])
    git!(["-C", repo, "checkout", "--quiet", "ticket"])
    commit_feature!(repo)

    assert :ok =
             PushSafety.install(repo, nil,
               base_branch: "develop",
               max_base_behind_commits: 1,
               max_untouched_deleted_files: 100
             )

    assert {output, status} =
             System.cmd("git", ["-C", repo, "push", "origin", "HEAD:refs/heads/ticket"], stderr_to_stdout: true)

    assert status != 0
    assert output =~ "refusing push"
    assert output =~ "2 commits behind origin/develop"
  end

  test "rejects mass deletions that no branch commit touched", %{repo: repo} do
    git!(["-C", repo, "branch", "ticket"])
    add_base_files!(repo, 2)
    git!(["-C", repo, "push", "--quiet", "origin", "develop"])
    git!(["-C", repo, "checkout", "--quiet", "ticket"])
    commit_feature!(repo)

    assert :ok =
             PushSafety.install(repo, nil,
               base_branch: "develop",
               max_base_behind_commits: 10,
               max_untouched_deleted_files: 1
             )

    assert {output, status} =
             System.cmd("git", ["-C", repo, "push", "origin", "HEAD:refs/heads/ticket"], stderr_to_stdout: true)

    assert status != 0
    assert output =~ "refusing push"
    assert output =~ "2 files from origin/develop that its commits never touched"
  end

  test "allows intentional deletions recorded by branch commits and preserves an existing hook", %{
    repo: repo
  } do
    add_base_files!(repo, 2)
    git!(["-C", repo, "push", "--quiet", "origin", "develop"])

    existing_hooks = Path.join(repo, "existing-hooks")
    marker = Path.join(repo, "original-hook-ran")
    File.mkdir_p!(existing_hooks)
    existing_hook = Path.join(existing_hooks, "pre-push")
    File.write!(existing_hook, "#!/bin/sh\nprintf ran > #{marker}\n")
    File.chmod!(existing_hook, 0o755)
    git!(["-C", repo, "config", "core.hooksPath", existing_hooks])

    git!(["-C", repo, "checkout", "--quiet", "-b", "ticket"])
    File.rm!(Path.join(repo, "base-1.txt"))
    File.rm!(Path.join(repo, "base-2.txt"))
    git!(["-C", repo, "add", "-u"])
    git!(["-C", repo, "commit", "--quiet", "-m", "intentional delete"])

    assert :ok =
             PushSafety.install(repo, nil,
               base_branch: "develop",
               max_base_behind_commits: 0,
               max_untouched_deleted_files: 0
             )

    assert {_output, 0} = System.cmd("git", ["-C", repo, "push", "--quiet", "origin", "ticket"], stderr_to_stdout: true)
    assert File.read!(marker) == "ran"
  end

  test "preserves an effective worktree-scoped hook", %{repo: repo} do
    existing_hooks = Path.join(repo, "worktree-hooks")
    marker = Path.join(repo, "worktree-hook-ran")
    File.mkdir_p!(existing_hooks)
    existing_hook = Path.join(existing_hooks, "pre-push")
    File.write!(existing_hook, "#!/bin/sh\nprintf ran > #{marker}\n")
    File.chmod!(existing_hook, 0o755)
    git!(["-C", repo, "config", "extensions.worktreeConfig", "true"])
    git!(["-C", repo, "config", "--worktree", "core.hooksPath", existing_hooks])

    assert :ok =
             PushSafety.install(repo, nil,
               base_branch: "develop",
               max_base_behind_commits: 10,
               max_untouched_deleted_files: 10
             )

    assert {_output, 0} =
             System.cmd("git", ["-C", repo, "push", "--quiet", "origin", "HEAD:refs/heads/ticket"], stderr_to_stdout: true)

    assert File.read!(marker) == "ran"
  end

  test "keeps an intact guard unchanged and repairs a non-executable hook", %{repo: repo} do
    opts = [base_branch: "develop", max_base_behind_commits: 10, max_untouched_deleted_files: 10]
    assert :ok = PushSafety.install(repo, nil, opts)

    hook = Path.join([repo, ".git", "aiur-hooks", "pre-push"])
    assert :ok = File.touch(hook, 1)
    assert :ok = PushSafety.install(repo, nil, opts)
    assert File.stat!(hook, time: :posix).mtime == 1

    assert :ok = File.chmod(hook, 0o600)
    assert :ok = PushSafety.install(repo, nil, opts)
    assert Bitwise.band(File.stat!(hook).mode, 0o100) == 0o100
  end

  test "rejects installation when the managed hook directory is a symlink", %{repo: repo} do
    outside = Path.join(Path.dirname(repo), "outside-hooks")
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join([repo, ".git", "aiur-hooks"]))

    assert {:error, {:push_safety_install_failed, ^repo, 32, output}} =
             PushSafety.install(repo, nil,
               base_branch: "develop",
               max_base_behind_commits: 10,
               max_untouched_deleted_files: 10
             )

    assert output =~ "refuses unsafe hook directory"
    refute File.exists?(Path.join(outside, "pre-push"))
  end

  test "times out a hung base refresh and refuses the push", %{repo: repo} do
    git!(["-C", repo, "checkout", "--quiet", "-b", "ticket"])
    commit_feature!(repo)

    assert :ok =
             PushSafety.install(repo, nil,
               base_branch: "develop",
               fetch_timeout_seconds: 1,
               max_base_behind_commits: 10,
               max_untouched_deleted_files: 10
             )

    git!(["-C", repo, "config", "remote.origin.uploadpack", "sh -c 'sleep 5'"])

    assert {output, status} =
             System.cmd("git", ["-C", repo, "push", "origin", "HEAD:refs/heads/ticket"], stderr_to_stdout: true)

    assert status != 0
    assert output =~ "could not be refreshed"
  end

  test "is a no-op for a workspace with no Git repository" do
    workspace = Path.join(System.tmp_dir!(), "aiur-push-safety-no-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    assert :ok =
             PushSafety.install(workspace, nil,
               base_branch: "develop",
               max_base_behind_commits: 10,
               max_untouched_deleted_files: 10
             )
  end

  defp add_base_files!(repo, count) do
    for index <- 1..count do
      path = Path.join(repo, "base-#{index}.txt")
      File.write!(path, "base #{index}\n")
      git!(["-C", repo, "add", Path.basename(path)])
      git!(["-C", repo, "commit", "--quiet", "-m", "base #{index}"])
    end
  end

  defp commit_feature!(repo) do
    File.write!(Path.join(repo, "feature.txt"), "feature\n")
    git!(["-C", repo, "add", "feature.txt"])
    git!(["-C", repo, "commit", "--quiet", "-m", "feature"])
  end

  defp git!(args) do
    {output, 0} = System.cmd("git", args, stderr_to_stdout: true)
    output
  end
end
