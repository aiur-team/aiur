Code.require_file("../../support/restack_fixture.ex", __DIR__)

defmodule Aiur.Stacking.RestackTest do
  use ExUnit.Case, async: true
  alias Aiur.Stacking.Restack
  alias Aiur.TestSupport.RestackFixture

  import Aiur.TestSupport.RestackFixture, only: [git: 2, command: 2]
  setup do: RestackFixture.create()

  test "custom base pushes only the dependent diff without touching the checkout; repeat is a no-op", ctx do
    {_, plain_status} = command(ctx.workspace, ["merge-tree", "--write-tree", "main", "dependent"])
    assert plain_status == 1
    hook = Path.join(ctx.workspace, ".git/hooks/pre-push")
    File.write!(hook, "#!/bin/sh\ntouch restack-hook-ran\n")
    File.chmod!(hook, 0o755)
    before = git(ctx.workspace, ["status", "--porcelain"])
    assert {:ok, {:pushed, sha}} = Restack.run(ctx.workspace, "dependent", 42, "main", ctx.merge)
    assert remote(ctx) == sha
    refute File.exists?(Path.join(ctx.workspace, "restack-hook-ran"))
    assert git(ctx.workspace, ["diff", "--name-only", "main", sha]) == "shared"
    assert git(ctx.workspace, ["show", "#{sha}:shared"]) == "dependent"
    assert git(ctx.workspace, ["rev-list", "--parents", "-n", "1", sha]) == "#{sha} #{ctx.dependent} #{ctx.merge}"
    assert {_, 0} = command(ctx.workspace, ["merge-base", "--is-ancestor", ctx.merge, sha])
    assert git(ctx.workspace, ["rev-parse", "HEAD"]) == ctx.dependent
    assert git(ctx.workspace, ["status", "--porcelain"]) == before
    assert git(ctx.workspace, ["show", "-s", "--format=%B", sha]) =~ "Aiur-Restack: blocker=#42 blocker-head="
    assert {:ok, :already_contained} = Restack.run(ctx.workspace, "dependent", 42, "main", ctx.merge)
    assert remote(ctx) == sha
  end

  test "a main change after the squash conflicts and leaves the remote unchanged", ctx do
    git(ctx.workspace, ["checkout", "main"])
    File.write!(Path.join(ctx.workspace, "shared"), "later main\n")
    commit(ctx.workspace, "later")
    git(ctx.workspace, ["push", "origin", "main"])
    assert {:conflict, ["shared"]} = Restack.run(ctx.workspace, "dependent", 42, "main", ctx.merge)
    assert remote(ctx) == ctx.dependent
  end

  test "a remote push racing the restack is rejected", ctx do
    cmd = fn path, args ->
      if hd(args) == "push" do
        File.write!(Path.join(path, "race"), "agent push\n")
        commit(path, "race")
        git(path, ["push", "origin", "dependent"])
      end

      command(path, args)
    end

    assert {:error, :remote_moved} = Restack.run(ctx.workspace, "dependent", 42, "main", ctx.merge, command: cmd)
    assert remote(ctx) == git(ctx.workspace, ["rev-parse", "HEAD"])
    refute remote(ctx) == ctx.dependent
  end

  test "missing blocker ref does not push", ctx do
    assert {:error, {:git_failed, "fetch"}} = Restack.run(ctx.workspace, "dependent", 43, "main", ctx.merge)
    assert remote(ctx) == ctx.dependent
  end

  test "a logical dependency without blocker history behaves like an ordinary merge", ctx do
    git(ctx.workspace, ["checkout", "main~1"])
    git(ctx.workspace, ["checkout", "-b", "logical"])
    File.write!(Path.join(ctx.workspace, "logical-only"), "own change\n")
    commit(ctx.workspace, "logical")
    before = git(ctx.workspace, ["rev-parse", "HEAD"])
    git(ctx.workspace, ["push", "origin", "logical"])
    assert {:ok, {:pushed, sha}} = Restack.run(ctx.workspace, "logical", 42, "main", ctx.merge)
    assert git(ctx.origin, ["rev-parse", "refs/heads/logical"]) == sha
    assert git(ctx.workspace, ["diff", "--name-only", "main", sha]) == "logical-only"
    assert {_, 0} = command(ctx.workspace, ["merge-base", "--is-ancestor", before, sha])
  end

  test "a blocker push the dependent missed arrives through the squash", ctx do
    git(ctx.workspace, ["checkout", "blocker"])
    File.write!(Path.join(ctx.workspace, "blocker-only"), "blocker later push\n")
    commit(ctx.workspace, "blocker later")
    git(ctx.workspace, ["push", "origin", "HEAD:refs/pull/42/head"])
    git(ctx.workspace, ["checkout", "main"])
    File.write!(Path.join(ctx.workspace, "blocker-only"), "blocker later push\n")
    commit(ctx.workspace, "main includes later blocker")
    git(ctx.workspace, ["push", "origin", "main"])
    assert {:ok, {:pushed, sha}} = Restack.run(ctx.workspace, "dependent", 42, "main", ctx.merge)
    assert remote(ctx) == sha
    assert git(ctx.workspace, ["show", "#{sha}:blocker-only"]) == "blocker later push"
    assert git(ctx.workspace, ["diff", "--name-only", "main", sha]) == "shared"
  end

  test "unsupported git stops before fetching or pushing", ctx do
    command = fn _path, ["version"] -> {"git version 2.39.5\n", 0} end
    assert {:error, :unsupported_git} = Restack.run(ctx.workspace, "dependent", 42, "main", ctx.merge, command: command)
    assert remote(ctx) == ctx.dependent
  end

  defp remote(ctx), do: git(ctx.origin, ["rev-parse", "refs/heads/dependent"])

  defp commit(path, message) do
    git(path, ["add", "."])
    git(path, ["commit", "-m", message])
  end
end
