defmodule Aiur.AgentGitHubGuard.OwnershipFenceTest do
  # Cohesion: runs the installed git/gh wrappers against a real fence socket.
  use Aiur.AgentGitHubGuardCase, async: true

  alias Aiur.GitHub.AgentBudgetSocket
  alias Aiur.Ownership.{Fence, FenceCommand, Record}

  @mine %Record{
    schema: "aiur.ownership/v1",
    repo: "o/r",
    ticket: "1670",
    state: "owned",
    gateway_id: "aaaaaaaaaaaaaaaaaaaaaaaaaa",
    gateway_label: "mine",
    daemon_key: "k1",
    epoch: 3,
    previous_epoch: 2,
    actor: %{kind: "daemon", id: "k1"},
    reason: "dispatch",
    at: "2026-11-08T00:00:00Z"
  }

  defp serve(_context, current) do
    {:ok, fence} = Fence.start_link(name: nil, read_fun: fn _, _, _ -> {:ok, %{record: current, oid: "x", repository_id: "r"}} end)
    :ok = Fence.register(%{identifier: "1670"}, @mine, fence)
    # A unix socket path must fit in ~100 bytes, which the long test tmp_dir does not.
    # AgentBudgetSocket chmods the socket's parent to 0700, so the socket gets its own directory.
    dir = Path.join(System.tmp_dir!(), "fence-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "s.sock")
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _} =
      AgentBudgetSocket.start_link(name: nil, socket_path: path, command_fun: &FenceCommand.execute(&1, server: fence))

    [{"AIUR_OWNERSHIP_FENCE_SOCKET", path}]
  end

  # A real repo with a local bare remote, so a push that gets through can never reach GitHub.
  defp local_remote(context) do
    init_git_workspace(context)
    remote = Path.join(context.tmp_dir, "remote.git")
    assert {_, 0} = System.cmd(real_git(), ["init", "--quiet", "--bare", remote], stderr_to_stdout: true)
    assert {_, 0} = System.cmd(real_git(), ["-C", context.workspace, "remote", "add", "origin", remote], stderr_to_stdout: true)
    remote
  end

  defp remote_heads(remote), do: elem(System.cmd(real_git(), ["-C", remote, "for-each-ref"], stderr_to_stdout: true), 0)

  defp gh(context, args, env) do
    System.cmd(context.wrapper, args,
      cd: context.workspace,
      env: [{"AIUR_REAL_GH", context.fake_gh}, {"AIUR_AGENT_WORKSPACE", context.workspace}] ++ env,
      stderr_to_stdout: true
    )
  end

  test "git push is refused once the ref moved to epoch 4", context do
    remote = local_remote(context)
    env = serve(context, %{@mine | epoch: 4}) |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
    assert {out, 77} = run_git_guard(context, ["push", "origin", "HEAD:refs/heads/main"], env)
    assert out =~ "ownership moved"
    assert out =~ "epoch=4"
    assert remote_heads(remote) == ""
  end

  test "git push goes through while the owner is unchanged", context do
    remote = local_remote(context)
    env = serve(context, @mine) |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
    assert {_, 0} = run_git_guard(context, ["push", "origin", "HEAD:refs/heads/main"], env)
    assert remote_heads(remote) =~ "refs/heads/main"
  end

  test "git push --dry-run is not fenced", context do
    local_remote(context)
    env = serve(context, %{@mine | epoch: 4}) |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
    {out, 0} = run_git_guard(context, ["push", "--dry-run", "origin", "HEAD:refs/heads/main"], env)
    refute out =~ "ownership"
  end

  test "an unreachable fence refuses the push and says why", context do
    remote = local_remote(context)
    env = [AIUR_OWNERSHIP_FENCE_SOCKET: Path.join(context.tmp_dir, "missing.sock")]
    assert {out, 75} = run_git_guard(context, ["push", "origin", "HEAD:refs/heads/main"], env)
    assert remote_heads(remote) == ""
    assert out =~ "ownership unverifiable"
    assert out =~ "unreachable"
  end

  test "without the fence socket nothing changes", context do
    local_remote(context)
    {out, 0} = run_git_guard(context, ["push", "--dry-run", "origin", "HEAD:refs/heads/main"])
    refute out =~ "ownership"
  end

  test "gh pr create, pr ready and PR-creating api calls are refused when moved", context do
    env = serve(context, %{@mine | epoch: 4})

    for args <- [
          ["pr", "create", "--title", "t"],
          ["pr", "ready"],
          ["api", "-X", "POST", "repos/o/r/pulls", "-f", "title=t"],
          ["api", "graphql", "-f", "query=mutation{createPullRequest(input:{}){clientMutationId}}"]
        ] do
      assert {out, 77} = gh(context, args, env)
      assert out =~ "ownership moved", inspect(args)
    end
  end

  test "gh pr create refuses when the fence is unreachable", context do
    assert {out, 75} = gh(context, ["pr", "create"], [{"AIUR_OWNERSHIP_FENCE_SOCKET", Path.join(context.tmp_dir, "missing.sock")}])
    assert out =~ "ownership unverifiable"
  end

  test "reversible gh commands are not fenced", context do
    env = serve(context, %{@mine | epoch: 4})
    {out, _} = gh(context, ["pr", "view"], env)
    refute out =~ "ownership"
  end
end
