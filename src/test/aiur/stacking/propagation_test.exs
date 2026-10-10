Code.require_file("../../support/restack_fixture.ex", __DIR__)

defmodule Aiur.Workspace.PropagationTest do
  use ExUnit.Case, async: true
  alias Aiur.TestSupport
  alias Aiur.TestSupport.RestackFixture, as: Git
  alias Aiur.Workspace.Restack

  setup do
    root = TestSupport.tmp_root!("propagation")
    origin = Path.join(root, "origin.git")
    work = Path.join(root, "work")
    File.mkdir_p!(work)
    Git.git(root, ["init", "--bare", origin])
    Git.git(work, ["init", "-b", "main"])
    Git.git(work, ["config", "user.name", "Propagation test"])
    Git.git(work, ["config", "user.email", "test@example.invalid"])
    Git.git(work, ["remote", "add", "origin", origin])
    File.write!(Path.join(work, "shared"), "initial\n")
    commit(work, "base")
    Git.git(work, ["checkout", "-b", "A"])
    File.write!(Path.join(work, "A"), "A\n")
    a = commit(work, "A")
    Git.git(work, ["checkout", "-b", "B"])
    File.write!(Path.join(work, "B"), "B\n")
    b = commit(work, "B")
    Git.git(work, ["checkout", "-b", "C"])
    File.write!(Path.join(work, "C"), "C\n")
    c = commit(work, "C")
    Git.git(work, ["push", "origin", "main", "A", "B", "C"])
    on_exit(fn -> File.rm_rf!(root) end)
    %{work: work, a: a, b: b, c: c}
  end

  defp commit(work, message) do
    Git.git(work, ["add", "."])
    Git.git(work, ["commit", "-m", message])
    Git.git(work, ["rev-parse", "HEAD"])
  end

  defp advance(ctx, file, content) do
    Git.git(ctx.work, ["checkout", "A"])
    File.write!(Path.join(ctx.work, file), content)
    sha = commit(ctx.work, "advance A")
    Git.git(ctx.work, ["push", "origin", "A"])
    %{ref: "refs/heads/A", previous_sha: ctx.a, sha: sha}
  end

  defp run(ctx, branch, number, push, head, opts \\ []) do
    Restack.propagate(ctx.work, branch, number, push, Keyword.merge([command: &Git.command/2, dependent_head: head], opts))
  end

  defp remote(ctx, branch), do: Git.git(ctx.work, ["ls-remote", "origin", "refs/heads/#{branch}"]) |> String.split() |> hd()

  test "three-level cascade preserves only C's files relative to updated B", ctx do
    push = advance(ctx, "A", "updated\n")
    assert {:ok, {:pushed, b}} = run(ctx, "B", 10, push, ctx.b)
    assert remote(ctx, "B") == b
    assert remote(ctx, "C") == ctx.c
    assert {:ok, {:pushed, c}} = run(ctx, "C", 20, %{ref: "refs/heads/B", previous_sha: ctx.b, sha: b}, ctx.c)
    assert remote(ctx, "C") == c
    assert {:ok, :already_contained} = run(ctx, "B", 10, %{push | previous_sha: nil}, b)
    assert {:ok, :already_contained} = run(ctx, "C", 20, %{ref: "refs/heads/B", previous_sha: ctx.a, sha: b}, c)
    assert Git.git(ctx.work, ["diff", "--name-only", b, c]) == "C"
    assert Git.git(ctx.work, ["show", "#{c}:A"]) == "updated"
    assert {_, 0} = Git.command(ctx.work, ["merge-base", "--is-ancestor", ctx.b, b])
    assert {_, 0} = Git.command(ctx.work, ["merge-base", "--is-ancestor", b, c])
  end

  test "conflicting blocker update writes neither B nor C", ctx do
    Git.git(ctx.work, ["checkout", "B"])
    File.write!(Path.join(ctx.work, "shared"), "B intent\n")
    b = commit(ctx.work, "B intent")
    Git.git(ctx.work, ["push", "origin", "B"])
    push = advance(ctx, "shared", "A intent\n")
    assert {:conflict, ["shared"]} = run(ctx, "B", 10, push, b)
    assert remote(ctx, "B") == b
    assert remote(ctx, "C") == ctx.c
  end

  test "an exact lease rejects a dependent moved backwards after the snapshot", ctx do
    push = advance(ctx, "A", "updated\n")

    before_push = fn ->
      Git.git(ctx.work, ["push", "--force", "origin", "#{ctx.a}:refs/heads/B"])
      :ok
    end

    assert {:error, :remote_moved} = run(ctx, "B", 10, push, ctx.b, before_push: before_push)
    assert remote(ctx, "B") == ctx.a
    assert remote(ctx, "C") == ctx.c
  end

  test "superseded work stops at the final push barrier", ctx do
    push = advance(ctx, "A", "updated\n")
    assert {:error, :superseded} = run(ctx, "B", 10, push, ctx.b, before_push: fn -> {:error, :superseded} end)
    assert remote(ctx, "B") == ctx.b
    assert remote(ctx, "C") == ctx.c
  end

  test "blocker rewrites leave both dependent branches intact", ctx do
    Git.git(ctx.work, ["checkout", "main"])
    Git.git(ctx.work, ["checkout", "-b", "rewritten"])
    File.write!(Path.join(ctx.work, "A"), "rewritten intent\n")
    sha = commit(ctx.work, "rewrite A")
    Git.git(ctx.work, ["push", "--force", "origin", "HEAD:refs/heads/A"])
    assert {:rewrite, []} = run(ctx, "B", 10, %{ref: "refs/heads/A", previous_sha: ctx.a, sha: sha}, ctx.b)
    assert remote(ctx, "B") == ctx.b
    assert remote(ctx, "C") == ctx.c
  end

  test "missing history is reported honestly and never pushed", ctx do
    push = advance(ctx, "A", "updated\n")
    assert {:history_unavailable, []} = run(ctx, "B", 10, %{push | previous_sha: nil}, ctx.b)
    assert {:history_unavailable, []} = run(ctx, "B", 10, %{push | previous_sha: String.duplicate("f", 40)}, ctx.b)
    assert remote(ctx, "B") == ctx.b
  end

  test "stale upstream or dependent evidence never writes a branch", ctx do
    push = advance(ctx, "A", "updated\n")
    assert {:error, :stale_evidence} = run(ctx, "B", 10, %{push | sha: ctx.a}, ctx.b)
    assert {:error, :stale_evidence} = run(ctx, "B", 10, push, ctx.c)
    assert remote(ctx, "B") == ctx.b
  end
end
