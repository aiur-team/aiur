defmodule Aiur.DogfoodHooksTest do
  use ExUnit.Case, async: true

  @hooks_path Path.expand("../../../.aiur/hooks", __DIR__)
  @repo_root Path.expand("../../..", __DIR__)
  @config_path Path.expand("../../../.aiur/config", __DIR__)
  @gitignore_path Path.expand("../../../.gitignore", __DIR__)
  @prompt_path Path.expand("../../../.aiur/prompt.md", __DIR__)
  @contributing_path Path.expand("../../../CONTRIBUTING.md", __DIR__)

  @external_resource @hooks_path
  @external_resource @config_path
  @external_resource @gitignore_path
  @external_resource @prompt_path
  @external_resource @contributing_path

  setup do
    test_root = Path.join(System.tmp_dir!(), "aiur-dogfood-hooks-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)
    on_exit(fn -> File.rm_rf!(test_root) end)

    {:ok, origin: origin, seed: seed} = create_origin!(test_root)
    {:ok, test_root: test_root, origin: origin, seed: seed}
  end

  test "dogfood config, hooks, and contributor guidance agree on the canonical branch" do
    assert {:ok, config} = YamlElixir.read_from_file(@config_path)
    dogfood_base = get_in(config, ["tracker", "base_branch"])
    assert dogfood_base == "main"

    hooks = dogfood_hooks!()
    assert hooks["after_create"] =~ ~s(base_branch="${THIS_BASE_BRANCH:-main}")
    assert hooks["before_run"] =~ ~s(base_branch="${THIS_BASE_BRANCH:-main}")
    refute File.read!(@hooks_path) =~ "origin/v2"

    prompt = File.read!(@prompt_path)
    assert prompt =~ "configured `tracker.base_branch` (`#{dogfood_base}` in this repository)"
    refute prompt =~ "against `v2`"

    contributing = File.read!(@contributing_path)
    assert contributing =~ "PRs target the canonical `#{dogfood_base}` branch"
    refute contributing =~ ~r/PRs target[^\n]*`v2`/
  end

  test "per-workspace package-manager caches are ignored and untracked" do
    for path <- [".aiur-hex/cache.ets", ".aiur-mix/archives/hex.ez"] do
      assert {_output, 0} =
               System.cmd("git", ["-C", @repo_root, "check-ignore", "--quiet", path], stderr_to_stdout: true)
    end

    assert {"", 0} =
             System.cmd("git", ["-C", @repo_root, "ls-files", ".aiur-hex", ".aiur-mix"], stderr_to_stdout: true)
  end

  test "checked-in hooks checkout and merge the configured base branch", context do
    workspace = Path.join(context.test_root, "configured-base")
    File.mkdir_p!(workspace)

    assert_hook_ok!("after_create", workspace, context.origin)
    assert current_branch!(workspace) == ticket_branch()
    assert File.read!(Path.join(workspace, "README.md")) == "stable one\n"

    File.write!(Path.join(context.seed, "README.md"), "stable two\n")
    git!(["-C", context.seed, "commit", "-am", "advance stable"])
    git!(["-C", context.seed, "push", "origin", configured_base()])

    assert_hook_ok!("before_run", workspace, context.origin)
    assert File.read!(Path.join(workspace, "README.md")) == "stable two\n"
  end

  test "before_run reconstructs a log-only workspace and preserves its logs", context do
    workspace = Path.join(context.test_root, "log-only")
    log_path = Path.join([workspace, "logs", "agent.md"])
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, "prior agent transcript\n")

    assert_hook_ok!("before_run", workspace, context.origin)

    assert File.dir?(Path.join(workspace, ".git"))
    assert current_branch!(workspace) == ticket_branch()
    assert File.read!(Path.join(workspace, "README.md")) == "stable one\n"
    assert File.read!(log_path) == "prior agent transcript\n"
  end

  test "before_run reconstructs a nested workspace without touching its parent repo", context do
    parent = Path.join(context.test_root, "parent-repo")
    workspace = Path.join([parent, "tickets", "1054"])
    parent_file = Path.join(parent, "PARENT.md")
    log_path = Path.join([workspace, "logs", "agent.md"])

    git!(["init", "--quiet", "--initial-branch=parent-main", parent])
    git!(["-C", parent, "config", "user.name", "Test User"])
    git!(["-C", parent, "config", "user.email", "test@example.com"])
    git!(["-C", parent, "remote", "add", "origin", context.origin])
    File.write!(Path.join(parent, ".gitignore"), "tickets/\n")
    File.write!(parent_file, "parent tree\n")
    git!(["-C", parent, "add", ".gitignore", "PARENT.md"])
    git!(["-C", parent, "commit", "--quiet", "-m", "parent tree"])

    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, "prior agent transcript\n")

    parent_head = git!(["-C", parent, "rev-parse", "HEAD"])
    assert String.trim(git!(["-C", workspace, "rev-parse", "--show-toplevel"])) == parent

    assert_hook_ok!("before_run", workspace, context.origin)

    assert File.dir?(Path.join(workspace, ".git"))
    assert current_branch!(workspace) == ticket_branch()
    assert File.read!(Path.join(workspace, "README.md")) == "stable one\n"
    assert File.read!(log_path) == "prior agent transcript\n"

    assert current_branch!(parent) == "parent-main"
    assert git!(["-C", parent, "rev-parse", "HEAD"]) == parent_head
    assert File.read!(parent_file) == "parent tree\n"
    assert String.trim(git!(["-C", parent, "status", "--short"])) == ""
  end

  test "before_run reports reconstruction failure and restores logs", context do
    workspace = Path.join(context.test_root, "failed-reconstruction")
    log_path = Path.join([workspace, "logs", "agent.md"])
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, "prior agent transcript\n")

    missing_origin = Path.join(context.test_root, "missing-origin.git")
    {output, status} = run_hook("before_run", workspace, missing_origin)

    refute status == 0, output
    refute File.dir?(Path.join(workspace, ".git"))
    assert File.read!(log_path) == "prior agent transcript\n"
  end

  test "before_run recovers a clean partial clone onto the ticket branch", context do
    workspace = Path.join(context.test_root, "partial-clone")
    git!(["clone", "--quiet", context.origin, workspace])

    assert current_branch!(workspace) == "main"
    assert_hook_ok!("before_run", workspace, context.origin)

    assert current_branch!(workspace) == ticket_branch()
    assert File.read!(Path.join(workspace, "README.md")) == "stable one\n"
  end

  test "before_run preserves a valid linked worktree", context do
    workspace = Path.join(context.test_root, "linked-worktree")

    git!([
      "-C",
      context.seed,
      "worktree",
      "add",
      "--quiet",
      "-b",
      ticket_branch(),
      workspace,
      configured_base()
    ])

    git_file = Path.join(workspace, ".git")
    assert File.regular?(git_file)
    worktree_link = File.read!(git_file)

    assert_hook_ok!("before_run", workspace, context.origin)

    assert File.regular?(git_file)
    assert File.read!(git_file) == worktree_link
    assert current_branch!(workspace) == ticket_branch()
  end

  test "before_run preserves tracked WIP on the wrong branch", context do
    workspace = Path.join(context.test_root, "dirty-partial-clone")
    git!(["clone", "--quiet", context.origin, workspace])
    File.write!(Path.join(workspace, "README.md"), "agent WIP\n")

    assert {output, 65} = run_hook("before_run", workspace, context.origin)
    assert output =~ "origin/#{configured_base()}"
    assert current_branch!(workspace) == "main"
    assert File.read!(Path.join(workspace, "README.md")) == "agent WIP\n"
  end

  test "before_run merges the base branch that stops tracking rewritten package caches", context do
    commit_legacy_package_caches!(context.seed)
    git!(["-C", context.seed, "push", "--quiet", "origin", configured_base()])

    workspace = Path.join(context.test_root, "legacy-package-cache")
    File.mkdir_p!(workspace)
    assert_hook_ok!("after_create", workspace, context.origin)
    git!(["-C", workspace, "config", "user.name", "Test User"])
    git!(["-C", workspace, "config", "user.email", "test@example.com"])

    File.write!(Path.join(workspace, "TICKET.md"), "intentional ticket work\n")
    git!(["-C", workspace, "add", "TICKET.md"])
    git!(["-C", workspace, "commit", "--quiet", "-m", "intentional ticket work"])

    File.write!(Path.join(workspace, ".aiur-hex/cache.ets"), "rewritten hex cache\n")
    File.write!(Path.join(workspace, ".aiur-mix/archives/hex.ez"), "rewritten mix cache\n")
    reused_package = Path.join(workspace, ".aiur-hex/packages/hexpm/reused.tar")
    File.mkdir_p!(Path.dirname(reused_package))
    File.write!(reused_package, "reusable package cache\n")

    commit_package_cache_deletion!(context.seed)
    git!(["-C", context.seed, "push", "--quiet", "origin", configured_base()])
    base_head = String.trim(git!(["-C", context.seed, "rev-parse", "HEAD"]))

    assert_hook_ok!("before_run", workspace, context.origin)

    assert {_, 0} =
             System.cmd("git", ["-C", workspace, "merge-base", "--is-ancestor", base_head, "HEAD"], stderr_to_stdout: true)

    assert File.read!(Path.join(workspace, "TICKET.md")) == "intentional ticket work\n"
    assert File.read!(Path.join(workspace, ".aiur-hex/cache.ets")) == "rewritten hex cache\n"
    assert File.read!(Path.join(workspace, ".aiur-mix/archives/hex.ez")) == "rewritten mix cache\n"
    assert File.read!(reused_package) == "reusable package cache\n"
    assert git!(["-C", workspace, "ls-files", ".aiur-hex", ".aiur-mix"]) == ""

    for path <- [".aiur-hex/cache.ets", ".aiur-mix/archives/hex.ez", ".aiur-hex/packages/hexpm/reused.tar"] do
      assert {_output, 0} = System.cmd("git", ["-C", workspace, "check-ignore", "--quiet", path])
    end

    assert String.trim(git!(["-C", workspace, "status", "--short"])) == ""
  end

  test "before_run restores rewritten package caches when the base merge fails", context do
    commit_legacy_package_caches!(context.seed)
    git!(["-C", context.seed, "push", "--quiet", "origin", configured_base()])

    workspace = Path.join(context.test_root, "failed-cache-transition")
    File.mkdir_p!(workspace)
    assert_hook_ok!("after_create", workspace, context.origin)
    git!(["-C", workspace, "config", "user.name", "Test User"])
    git!(["-C", workspace, "config", "user.email", "test@example.com"])

    File.write!(Path.join(workspace, "README.md"), "ticket branch conflict\n")
    git!(["-C", workspace, "commit", "--quiet", "-am", "ticket branch conflict"])
    File.write!(Path.join(workspace, ".aiur-hex/cache.ets"), "rewritten hex cache\n")
    File.write!(Path.join(workspace, ".aiur-mix/archives/hex.ez"), "rewritten mix cache\n")
    reused_package = Path.join(workspace, ".aiur-hex/packages/hexpm/reused.tar")
    File.mkdir_p!(Path.dirname(reused_package))
    File.write!(reused_package, "reusable package cache\n")

    File.write!(Path.join(context.seed, "README.md"), "base branch conflict\n")
    git!(["-C", context.seed, "add", "README.md"])
    commit_package_cache_deletion!(context.seed)
    git!(["-C", context.seed, "push", "--quiet", "origin", configured_base()])

    assert {output, status} = run_hook("before_run", workspace, context.origin)
    refute status == 0
    assert output =~ "CONFLICT"
    assert File.read!(Path.join(workspace, ".aiur-hex/cache.ets")) == "rewritten hex cache\n"
    assert File.read!(Path.join(workspace, ".aiur-mix/archives/hex.ez")) == "rewritten mix cache\n"
    assert File.read!(reused_package) == "reusable package cache\n"
  end

  test "before_run refuses to overwrite tracked WIP", context do
    workspace = Path.join(context.test_root, "dirty-workspace")
    File.mkdir_p!(workspace)
    assert_hook_ok!("after_create", workspace, context.origin)

    File.write!(Path.join(workspace, "README.md"), "agent WIP\n")

    assert {output, 65} = run_hook("before_run", workspace, context.origin)
    assert output =~ "origin/#{configured_base()}"
    assert File.read!(Path.join(workspace, "README.md")) == "agent WIP\n"
    assert current_branch!(workspace) == ticket_branch()
  end

  defp commit_legacy_package_caches!(repo) do
    for path <- [".aiur-hex/cache.ets", ".aiur-mix/archives/hex.ez"] do
      full_path = Path.join(repo, path)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, "legacy package cache\n")
      git!(["-C", repo, "add", "--force", path])
    end

    git!(["-C", repo, "commit", "--quiet", "-m", "track legacy package caches"])
  end

  defp commit_package_cache_deletion!(repo) do
    git!(["-C", repo, "rm", "-r", ".aiur-hex", ".aiur-mix"])
    File.write!(Path.join(repo, ".gitignore"), "/.aiur-hex/\n/.aiur-mix/\n")
    git!(["-C", repo, "add", ".gitignore"])
    git!(["-C", repo, "commit", "--quiet", "-m", "stop tracking package caches"])
  end

  defp create_origin!(test_root) do
    origin = Path.join(test_root, "origin.git")
    seed = Path.join(test_root, "seed")

    git!(["init", "--bare", "--quiet", "--initial-branch=main", origin])
    git!(["clone", "--quiet", origin, seed])
    git!(["-C", seed, "config", "user.name", "Test User"])
    git!(["-C", seed, "config", "user.email", "test@example.com"])

    File.write!(Path.join(seed, "README.md"), "main\n")
    git!(["-C", seed, "add", "README.md"])
    git!(["-C", seed, "commit", "--quiet", "-m", "main"])
    git!(["-C", seed, "push", "--quiet", "origin", "main"])

    git!(["-C", seed, "checkout", "--quiet", "-b", configured_base()])
    File.write!(Path.join(seed, "README.md"), "stable one\n")
    git!(["-C", seed, "commit", "--quiet", "-am", "stable one"])
    git!(["-C", seed, "push", "--quiet", "-u", "origin", configured_base()])

    {:ok, origin: origin, seed: seed}
  end

  defp assert_hook_ok!(name, workspace, origin) do
    {output, status} = run_hook(name, workspace, origin)
    assert status == 0, output
  end

  defp run_hook(name, workspace, origin) do
    System.cmd("sh", ["-lc", Map.fetch!(dogfood_hooks!(), name)],
      cd: workspace,
      stderr_to_stdout: true,
      env: [
        {"THIS_REPOSITORY_URL", origin},
        {"THIS_BASE_BRANCH", configured_base()},
        {"AIUR_TICKET_BRANCH", ticket_branch()}
      ]
    )
  end

  defp dogfood_hooks! do
    {:ok, hooks} = YamlElixir.read_from_file(@hooks_path)
    hooks
  end

  defp current_branch!(repo) do
    repo
    |> then(&git!(["-C", &1, "branch", "--show-current"]))
    |> String.trim()
  end

  defp git!(args) do
    {output, 0} = System.cmd("git", args, stderr_to_stdout: true)
    output
  end

  defp configured_base, do: "stable"
  defp ticket_branch, do: "aiur/1054-test"
end
