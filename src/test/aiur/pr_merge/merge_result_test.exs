defmodule Aiur.PrMerge.MergeResultTest do
  use ExUnit.Case, async: true
  alias Aiur.PrMerge.MergeResult
  alias Aiur.TestSupport.RestackFixture

  setup do
    root = Path.join(System.tmp_dir!(), "merge-git-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "origin")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-b", "integration"])
    git!(repo, ["config", "user.name", "Test"])
    git!(repo, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(repo, "file"), "first\nmiddle\nlast\n")
    git!(repo, ["add", "file"])
    git!(repo, ["commit", "-m", "Initial"])
    initial = git!(repo, ["rev-parse", "HEAD"])
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    {:ok, root: root, repo: repo, initial: initial}
  end

  defp git!(repo, args) do
    {output, status} = RestackFixture.command(repo, args)
    assert status == 0, output
    String.trim(output)
  end

  defp branch(ctx, content, base_content \\ nil) do
    git!(ctx.repo, ["checkout", "-b", "feature"])
    File.write!(Path.join(ctx.repo, "file"), content)
    git!(ctx.repo, ["commit", "-am", "Feature"])
    head = git!(ctx.repo, ["rev-parse", "HEAD"])
    git!(ctx.repo, ["update-ref", "refs/pull/1/head", head])
    git!(ctx.repo, ["checkout", "integration"])

    if base_content do
      File.write!(Path.join(ctx.repo, "file"), base_content)
      git!(ctx.repo, ["commit", "-am", "Base"])
    end

    %{number: 1, base: "integration", head: head, base_sha: git!(ctx.repo, ["rev-parse", "HEAD"])}
  end

  defp check(ctx, pr, commands, extra \\ []) do
    settings = %{workspace: %{root: Path.join(ctx.root, "agents")}, merge_policy: %{premerge_checks: commands}}
    runner = fn repo, args, _env -> {:ok, RestackFixture.command(repo, args)} end
    opts = [run: runner, repo: Path.join(ctx.root, "cache.git"), remote: ctx.repo, log_root: Path.join(ctx.root, "logs"), puts: fn line -> send(self(), {:output, line}) end]
    MergeResult.check(pr, settings, Keyword.merge(opts, extra))
  end

  defp clean?(ctx) do
    assert File.ls!(Path.join(ctx.root, "cache.git")) == []
    premerge = Path.join(ctx.root, "agents/premerge")
    assert not File.exists?(premerge) or File.ls!(premerge) == []
  end

  test "conflicts refuse and clean all fetched refs", ctx do
    pr = branch(ctx, "feature\nmiddle\nlast\n", "base\nmiddle\nlast\n")
    assert check(ctx, pr, []) == {:refuse, ["conflict"]}
    clean?(ctx)
  end

  test "premerge checks see the merge result and overlap is informational", ctx do
    pr = branch(ctx, "feature\nmiddle\nlast\n", "first\nmiddle\nbase\n")
    assert check(ctx, pr, ["test \"$(cat file)\" = \"$(printf 'feature\\nmiddle\\nbase')\""]) == :ok
    assert_received {:output, "NOTE overlap: file"}
    clean?(ctx)
    assert git!(ctx.repo, ["rev-parse", "HEAD"]) == pr.base_sha
  end

  test "base-dependent premerge commands have the pinned origin ref", ctx do
    pr = branch(ctx, "feature\nmiddle\nlast\n")
    command = "test \"$(git -C \"$PWD\" rev-parse origin/integration)\" = #{pr.base_sha}"
    assert check(ctx, pr, [command]) == :ok
    clean?(ctx)
  end

  test "concurrent invocations cannot remove each other's worktree or log", ctx do
    pr = branch(ctx, "feature\nmiddle\nlast\n")
    paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))
    args = Enum.flat_map(paths, &["-pa", &1])
    settings = %{workspace: %{root: Path.join(ctx.root, "agents")}, merge_policy: %{premerge_checks: ["echo owned-check; test -f file"]}}
    git = System.get_env("AIUR_REAL_GIT") || System.find_executable("git")

    script = """
    runner = fn repo, args, _env -> {:ok, System.cmd(#{inspect(git)}, ["-C", repo | args], stderr_to_stdout: true)} end
    result = Aiur.PrMerge.MergeResult.check(#{inspect(pr)}, #{inspect(settings)},
      repo: #{inspect(Path.join(ctx.root, "cache.git"))}, remote: #{inspect(ctx.repo)},
      log_root: #{inspect(Path.join(ctx.root, "logs"))}, run: runner)
    if result != :ok, do: raise(inspect(result))
    """

    tasks = for _ <- 1..2, do: Task.async(fn -> System.cmd("elixir", args ++ ["-e", script], env: [{"ERL_FLAGS", "+S 2:2"}], stderr_to_stdout: true) end)
    results = Enum.map(tasks, &Task.await(&1, 30_000))
    assert Enum.all?(results, fn {_output, status} -> status == 0 end), inspect(results)
    logs = ctx.root |> Path.join("logs") |> File.ls!()
    assert length(logs) == 2
    clean?(ctx)
  end

  test "failed premerge logs its tail and removes the worktree", ctx do
    pr = branch(ctx, "feature\nmiddle\nlast\n")
    assert {:refuse, [reason]} = check(ctx, pr, ["echo structural-failure; exit 4"])
    assert reason =~ "premerge check failed"
    assert reason =~ "structural-failure"
    clean?(ctx)
  end

  test "bounded premerge commands time out and leave no worktree", ctx do
    pr = branch(ctx, "feature\nmiddle\nlast\n")
    assert {:refuse, [reason]} = check(ctx, pr, ["sleep 60"], timeout_ms: 10)
    assert reason =~ "premerge check timed out"
    clean?(ctx)
  end

  test "fetching a changed head or base refuses the unreviewed result", ctx do
    pr = branch(ctx, "feature\nmiddle\nlast\n")
    assert check(ctx, %{pr | head: ctx.initial}, []) == {:refuse, ["head moved during fetch"]}
    assert check(ctx, %{pr | base_sha: pr.head}, []) == {:refuse, ["base moved during fetch"]}
    clean?(ctx)
  end
end
