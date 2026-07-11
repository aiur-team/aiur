defmodule Aiur.Workspace.CheckoutTest do
  use ExUnit.Case, async: true

  alias Aiur.Workspace.Checkout

  setup do
    tmp = Path.join(System.tmp_dir!(), "aiur-checkout-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "current_branch returns the checked out branch and nil for a non git dir", %{tmp: tmp} do
    repo = init_repo!(Path.join(tmp, "repo"))
    non_git = Path.join(tmp, "non-git")
    File.mkdir_p!(non_git)

    assert Checkout.current_branch(repo) == "main"
    assert Checkout.current_branch(non_git) == nil
  end

  test "checkout_fresh_branch falls back to copied HEAD when no remote is usable", %{tmp: tmp} do
    repo = init_repo!(Path.join(tmp, "123"))

    assert :ok = Checkout.checkout_fresh_branch(repo)
    assert Checkout.current_branch(repo) == "aiur/123"
  end

  test "checkout_fresh_branch uses the supplied generated ticket branch", %{tmp: tmp} do
    repo = init_repo!(Path.join(tmp, "123"))

    assert :ok = Checkout.checkout_fresh_branch(repo, "aiur/123-add-new-test-cases")
    assert Checkout.current_branch(repo) == "aiur/123-add-new-test-cases"
  end

  test "checkout_fresh_branch resumes an existing remote ticket branch", %{tmp: tmp} do
    remote = Path.join(tmp, "remote.git")
    source = Path.join(tmp, "source")
    workspace = Path.join(tmp, "workspace")
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
  end

  test "checkout_existing_pr_branch falls back to a local branch named the ref", %{tmp: tmp} do
    repo = init_repo!(Path.join(tmp, "pr-77"))

    assert :ok = Checkout.checkout_existing_pr_branch(repo, "feature/login")
    assert Checkout.current_branch(repo) == "feature/login"
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
