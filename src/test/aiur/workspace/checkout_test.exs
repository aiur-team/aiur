defmodule Aiur.Workspace.CheckoutTest do
  use ExUnit.Case, async: true

  alias Aiur.Workspace.Checkout

  setup do
    root = Path.join(System.tmp_dir!(), "workspace-checkout-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "rejects an unborn or interrupted git init", %{root: root} do
    workspace = Path.join(root, "unborn")
    File.mkdir_p!(workspace)
    git!(["init", "--quiet", workspace])

    refute Checkout.valid_workspace?(workspace)
  end

  test "accepts a dirty checkout with a committed HEAD", %{root: root} do
    workspace = init_repo!(Path.join(root, "dirty"))
    File.write!(Path.join(workspace, "README.md"), "uncommitted WIP\n")

    assert Checkout.valid_workspace?(workspace)
  end

  test "accepts a linked worktree with a committed HEAD", %{root: root} do
    source = init_repo!(Path.join(root, "source"))
    workspace = Path.join(root, "linked")
    git!(["-C", source, "worktree", "add", "--quiet", "-b", "ticket-branch", workspace])

    assert File.regular?(Path.join(workspace, ".git"))
    assert Checkout.valid_workspace?(workspace)
  end

  test "current_branch returns the checked out branch and nil for a non git dir", %{root: root} do
    repo = init_repo!(Path.join(root, "repo"))
    non_git = Path.join(root, "non-git")
    File.mkdir_p!(non_git)

    assert Checkout.current_branch(repo) == "main"
    assert Checkout.current_branch(non_git) == nil
  end

  test "checkout_fresh_branch falls back to copied HEAD when no remote is usable", %{root: root} do
    repo = init_repo!(Path.join(root, "123"))

    assert :ok = Checkout.checkout_fresh_branch(repo)
    assert Checkout.current_branch(repo) == "aiur/123"
    assert branch_start(repo) == head(repo)
  end

  test "checkout_fresh_branch uses the supplied generated ticket branch", %{root: root} do
    repo = init_repo!(Path.join(root, "123"))

    assert :ok = Checkout.checkout_fresh_branch(repo, "aiur/123-add-new-test-cases")
    assert Checkout.current_branch(repo) == "aiur/123-add-new-test-cases"
  end

  test "checkout_fresh_branch resumes an existing remote ticket branch", %{root: root} do
    remote = Path.join(root, "remote.git")
    source = Path.join(root, "source")
    workspace = Path.join(root, "workspace")
    branch = "aiur/123-fix-login"

    git!(["init", "--bare", "--quiet", "--initial-branch=main", remote])
    init_repo!(source)
    git!(["-C", source, "remote", "add", "origin", remote])
    git!(["-C", source, "push", "--quiet", "origin", "main"])
    git!(["-C", source, "checkout", "--quiet", "-b", branch])
    File.write!(Path.join(source, "resume.txt"), "remote ticket work\n")
    git!(["-C", source, "add", "."])
    git!(["-C", source, "commit", "--quiet", "-m", "ticket work"])
    git!(["-C", source, "push", "--quiet", "origin", branch])
    git!(["clone", "--quiet", remote, workspace])

    assert :ok = Checkout.checkout_fresh_branch(workspace, branch)
    assert Checkout.current_branch(workspace) == branch
    assert File.read!(Path.join(workspace, "resume.txt")) == "remote ticket work\n"
    assert branch_start(workspace) == git_sha!(workspace, ["merge-base", "origin/main", "HEAD"])
  end

  test "checkout_existing_pr_branch falls back to a local branch named the ref", %{root: root} do
    repo = init_repo!(Path.join(root, "pr-77"))

    assert :ok = Checkout.checkout_existing_pr_branch(repo, "feature/login")
    assert Checkout.current_branch(repo) == "feature/login"
  end

  defp init_repo!(workspace) do
    File.mkdir_p!(workspace)
    git!(["init", "--quiet", "-b", "main", workspace])
    git!(["-C", workspace, "config", "user.email", "test@example.com"])
    git!(["-C", workspace, "config", "user.name", "Test"])
    File.write!(Path.join(workspace, "README.md"), "initial\n")
    git!(["-C", workspace, "add", "."])
    git!(["-C", workspace, "commit", "--quiet", "-m", "initial"])
    workspace
  end

  defp git!(args) do
    {output, 0} = System.cmd("git", args, stderr_to_stdout: true)
    output
  end

  defp branch_start(workspace), do: git_sha!(workspace, ["rev-parse", "refs/aiur/branch-start"])
  defp head(workspace), do: git_sha!(workspace, ["rev-parse", "HEAD"])

  defp git_sha!(workspace, args) do
    ["-C", workspace | args]
    |> git!()
    |> String.trim()
  end
end
