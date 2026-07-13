defmodule Aiur.DogfoodHooksTest do
  use ExUnit.Case, async: true

  @hooks_path Path.expand("../../../.aiur/hooks", __DIR__)
  @config_path Path.expand("../../../.aiur/config", __DIR__)
  @prompt_path Path.expand("../../../.aiur/prompt.md", __DIR__)
  @contributing_path Path.expand("../../../CONTRIBUTING.md", __DIR__)

  @external_resource @hooks_path
  @external_resource @config_path
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
