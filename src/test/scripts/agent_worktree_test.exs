defmodule Aiur.Scripts.AgentWorktreeTest do
  @moduledoc """
  Guards #2362: concurrent review agents on one box share a scratchpad root
  and used to create worktrees at the same generic path (`wt/`, `worktree`,
  `pr`, `build`), letting the second agent silently repoint the first's
  checkout at a different branch mid-run so mutation tests ran against the
  wrong tree. `scripts/agent-worktree` gives every worktree a collision-proof
  path and branch (PR number + per-agent unique component), fails loudly when
  the target path already exists, prunes stale worktrees, and asserts a
  worktree's HEAD matches the intended SHA before a mutation batch.
  """
  use ExUnit.Case, async: true

  @helper Path.expand("../../../scripts/agent-worktree", __DIR__)

  # Run git and the helper against the REAL git binary. In an agent workspace
  # PATH, bare `git` resolves to the guard wrapper, which is a separate,
  # deliberately-stricter surface (tested in `agent_github_guard_test.exs`).
  # Here the helper's own logic is the unit under test.
  defp real_git, do: System.get_env("AIUR_REAL_GIT") || System.find_executable("git")

  defp clean_env(extra \\ []) do
    git_dir = Path.dirname(real_git())

    [
      {"PATH", git_dir <> ":/usr/bin:/bin"},
      {"AIUR_REAL_GIT", real_git()}
    ] ++ extra
  end

  # `System.cmd("git", ...)` resolves the executable from the Erlang VM's PATH,
  # not the `env:` option, so the wrapper would be found here. Passing the
  # absolute real-git path keeps these fixtures on the real binary.
  defp git!(repo, args) do
    {output, 0} = System.cmd(real_git(), args, cd: repo, env: clean_env(), stderr_to_stdout: true)
    String.trim(output)
  end

  defp run_helper!(repo, args) do
    System.cmd(@helper, args, cd: repo, env: clean_env(), stderr_to_stdout: true)
  end

  defp write!(repo, path, contents) do
    File.write!(Path.join(repo, path), contents)
  end

  defp commit_all!(repo, message) do
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", message])
  end

  defp new_repo! do
    root = Path.join(System.tmp_dir!(), "aiur-agent-worktree-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    origin = Path.join(root, "origin.git")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.name", "Aiur Test"])
    git!(repo, ["config", "user.email", "aiur@example.test"])
    git!(root, ["init", "--bare", "-q", origin])
    git!(repo, ["remote", "add", "origin", origin])
    write!(repo, "README.md", "seed\n")
    commit_all!(repo, "seed")
    git!(repo, ["push", "-q", "-u", "origin", "main"])
    on_exit(fn -> File.rm_rf!(root) end)
    {repo, origin}
  end

  # Publish a PR head ref on the origin remote and return its commit sha. The
  # local `main` branch stays behind the PR change, so a correctly-checked-out
  # worktree is observably at the PR head, not at main.
  defp add_pr!(repo, pr) do
    branch = "feature-#{pr}"
    git!(repo, ["checkout", "-q", "-b", branch])
    write!(repo, "feature-#{pr}.txt", "feature #{pr}\n")
    commit_all!(repo, "feature for pr #{pr}")
    head = git!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["push", "-q", "origin", "#{branch}:refs/pull/#{pr}/head"])
    git!(repo, ["checkout", "-q", "main"])
    head
  end

  test "path prints a collision-proof path carrying the PR number and a unique component" do
    {repo, _origin} = new_repo!()

    {out1, 0} = run_helper!(repo, ["path", "123"])
    {out2, 0} = run_helper!(repo, ["path", "123"])
    path1 = String.trim(out1)
    path2 = String.trim(out2)

    # PR number is embedded and recognizable
    assert path1 =~ ".worktrees/pr-123-"
    # a per-agent unique component makes every call distinct
    assert path1 != path2
    # `path` prints a candidate; it creates nothing
    refute File.dir?(path1)
  end

  test "create checks out the PR head in a unique worktree with a unique branch" do
    {repo, _origin} = new_repo!()
    pr_head = add_pr!(repo, 123)

    {out, 0} = run_helper!(repo, ["create", "123"])
    path = String.trim(out)

    assert path =~ ".worktrees/pr-123-"
    assert File.dir?(path)
    # the worktree is at the PR head commit, not at main
    assert git!(path, ["rev-parse", "HEAD"]) == pr_head
    assert git!(path, ["rev-parse", "HEAD"]) != git!(repo, ["rev-parse", "HEAD"])
    # the local branch mirrors the unique path, so two same-PR agents never
    # collide on the branch name either
    assert git!(path, ["branch", "--show-current"]) =~ "pr-123-"
  end

  test "two concurrent worktree creations for the same PR get distinct paths and both succeed" do
    {repo, _origin} = new_repo!()
    pr_head = add_pr!(repo, 123)

    results =
      1..2
      |> Task.async_stream(fn _ -> run_helper!(repo, ["create", "123"]) end,
        max_concurrency: 2,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, {out, status}} -> {String.trim(out), status} end)

    assert Enum.all?(results, fn {_path, status} -> status == 0 end),
           "both concurrent creations must succeed: #{inspect(results)}"

    paths = Enum.map(results, fn {path, _status} -> path end)
    assert length(Enum.uniq(paths)) == 2, "concurrent same-PR paths must be distinct"
    assert Enum.all?(paths, &File.dir?/1)
    Enum.each(paths, fn path -> assert git!(path, ["rev-parse", "HEAD"]) == pr_head end)
  end

  test "create refuses an existing worktree path instead of reusing or repointing it" do
    {repo, _origin} = new_repo!()
    add_pr!(repo, 123)

    {out1, 0} = run_helper!(repo, ["create", "123", "--unique", "fixed"])
    path = String.trim(out1)
    assert File.dir?(path)

    # The same --unique path is taken: creation must fail loudly (exit 64)
    {out2, 64} = run_helper!(repo, ["create", "123", "--unique", "fixed"])
    assert out2 =~ "refusing create"
    assert out2 =~ "already exists"
    assert out2 =~ "do not reuse or repoint"

    # the original worktree is untouched
    assert git!(path, ["branch", "--show-current"]) == "pr-123-fixed"
  end

  test "prune removes worktrees whose branch is merged into the base and keeps the rest" do
    {repo, _origin} = new_repo!()
    add_pr!(repo, 123)
    add_pr!(repo, 456)

    {out1, 0} = run_helper!(repo, ["create", "123", "--unique", "merged"])
    {out2, 0} = run_helper!(repo, ["create", "456", "--unique", "kept"])
    path_merged = String.trim(out1)
    path_kept = String.trim(out2)
    branch_merged = git!(path_merged, ["branch", "--show-current"])

    # merge the first worktree's branch into main so it becomes stale
    git!(repo, ["merge", "-q", "--no-edit", "-m", "merge", branch_merged])

    # dry-run reports but removes nothing
    {dry, 0} = run_helper!(repo, ["prune", "--base", "main", "--dry-run"])
    assert dry =~ "would remove stale worktree"
    assert dry =~ path_merged
    assert File.dir?(path_merged)

    # real prune removes the merged worktree and keeps the unmerged one and the
    # main checkout
    {out, 0} = run_helper!(repo, ["prune", "--base", "main"])
    assert out =~ "removed stale worktree"
    assert out =~ path_merged
    refute File.dir?(path_merged)
    assert File.dir?(path_kept)
    assert git!(repo, ["rev-parse", "--show-toplevel"]) == repo
  end

  test "list shows the registered worktrees with their branches" do
    {repo, _origin} = new_repo!()
    add_pr!(repo, 123)

    {out, 0} = run_helper!(repo, ["create", "123", "--unique", "listed"])
    path = String.trim(out)

    {list_out, 0} = run_helper!(repo, ["list"])
    assert list_out =~ path
    assert list_out =~ "pr-123-listed"
  end

  test "head-check passes when the worktree is at the intended SHA and fails loudly on drift" do
    {repo, _origin} = new_repo!()
    pr_head = add_pr!(repo, 123)

    {out, 0} = run_helper!(repo, ["create", "123", "--unique", "checked"])
    path = String.trim(out)

    # matching SHA passes (exit 0)
    {ok_out, 0} = run_helper!(repo, ["head-check", path, pr_head])
    assert ok_out =~ "HEAD ok"

    # drift from the intended SHA aborts loudly (exit 65), like a worktree
    # repointed at a different branch mid-run would
    write!(path, "drift.txt", "drift\n")
    git!(path, ["add", "-A"])
    git!(path, ["commit", "-q", "-m", "drift"])
    assert git!(path, ["rev-parse", "HEAD"]) != pr_head

    {drift_out, 65} = run_helper!(repo, ["head-check", path, pr_head])
    assert drift_out =~ "HEAD DRIFT"
    assert drift_out =~ "aborting"
    # the worktree still has the drifted content; only the check refused
    assert git!(path, ["rev-parse", "HEAD"]) != pr_head
  end

  test "head-check requires a 40-hex sha and reports a path that is not a git worktree" do
    {repo, _origin} = new_repo!()
    add_pr!(repo, 123)

    {out, 0} = run_helper!(repo, ["create", "123", "--unique", "strict"])
    path = String.trim(out)

    {bad_sha, 1} = run_helper!(repo, ["head-check", path, "not-a-sha"])
    assert bad_sha =~ "40-hex commit sha"

    not_a_repo =
      Path.join(System.tmp_dir!(), "aiur-not-a-worktree-#{System.unique_integer([:positive])}")

    File.mkdir_p!(not_a_repo)
    on_exit(fn -> File.rm_rf!(not_a_repo) end)

    # A real directory under the workspace would inherit the workspace repo via
    # git's upward walk, so give it a `.git` gitfile pointing nowhere to make it
    # genuinely not a git worktree.
    File.write!(Path.join(not_a_repo, ".git"), "gitdir: /nonexistent-aiur-#{System.unique_integer([:positive])}\n")

    {not_wt, 64} = run_helper!(repo, ["head-check", not_a_repo, String.duplicate("a", 40)])
    assert not_wt =~ "not a git worktree"
  end
end
