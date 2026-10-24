defmodule Aiur.DogfoodHooksFetchTest do
  use ExUnit.Case, async: true

  @hooks_path Path.expand("../../../.aiur/hooks", __DIR__)

  @external_resource @hooks_path

  setup do
    test_root = Aiur.TestSupport.tmp_root!("aiur-dogfood-hooks-fetch")
    File.mkdir_p!(test_root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(test_root) end)

    {:ok, origin: origin, seed: seed} = create_origin!(test_root)
    {:ok, test_root: test_root, origin: origin, seed: seed}
  end

  test "before_run fetches the ticket branch without fetching unrelated remote branches", context do
    workspace = Path.join(context.test_root, "targeted-fetch")
    File.mkdir_p!(workspace)
    assert_hook_ok!("after_create", workspace, context.origin)

    git!(["-C", context.seed, "checkout", "--quiet", "-b", ticket_branch(), configured_base()])
    File.write!(Path.join(context.seed, "ticket.txt"), "ticket branch\n")
    git!(["-C", context.seed, "add", "ticket.txt"])
    git!(["-C", context.seed, "commit", "--quiet", "-m", "ticket branch"])
    git!(["-C", context.seed, "push", "--quiet", "origin", ticket_branch()])

    git!(["-C", context.seed, "checkout", "--quiet", "-b", "unrelated/remote", configured_base()])
    File.write!(Path.join(context.seed, "unrelated.txt"), "unrelated branch\n")
    git!(["-C", context.seed, "add", "unrelated.txt"])
    git!(["-C", context.seed, "commit", "--quiet", "-m", "unrelated branch"])
    git!(["-C", context.seed, "push", "--quiet", "origin", "unrelated/remote"])

    assert_hook_ok!("before_run", workspace, context.origin)

    assert git!(["-C", workspace, "rev-parse", "refs/remotes/origin/#{configured_base()}"]) != ""
    assert git!(["-C", workspace, "rev-parse", "refs/remotes/origin/#{ticket_branch()}"]) != ""

    assert {_, 1} =
             System.cmd(real_git(), ["-C", workspace, "show-ref", "--verify", "--quiet", "refs/remotes/origin/unrelated/remote"])

    assert git!(["-C", workspace, "show", "origin/#{ticket_branch()}:ticket.txt"]) == "ticket branch\n"
  end

  test "before_run stops when it cannot check whether the remote ticket branch exists", context do
    workspace = Path.join(context.test_root, "ticket-check-failure")
    wrapper_dir = Path.join(context.test_root, "git-wrapper")
    File.mkdir_p!(workspace)
    File.mkdir_p!(wrapper_dir)
    assert_hook_ok!("after_create", workspace, context.origin)

    wrapper = Path.join(wrapper_dir, "git")

    File.write!(wrapper, """
    #!/bin/sh
    if [ "$1" = "ls-remote" ]; then
      echo "simulated remote failure" >&2
      exit 128
    fi
    exec #{inspect(real_git())} "$@"
    """)

    File.chmod!(wrapper, 0o755)

    {output, status} = run_hook("before_run", workspace, context.origin, wrapper_dir)
    assert status == 128
    assert output =~ "simulated remote failure"
    assert output =~ "Unable to check remote ticket branch #{ticket_branch()}"
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

  defp run_hook(name, workspace, origin, path_prefix \\ nil) do
    {:ok, hooks} = YamlElixir.read_from_file(@hooks_path)

    System.cmd("sh", ["-c", Map.fetch!(hooks, name)],
      cd: workspace,
      stderr_to_stdout: true,
      env: [
        {"PATH", Enum.join(Enum.reject([path_prefix, fixture_path()], &is_nil/1), ":")},
        {"THIS_REPOSITORY_URL", origin},
        {"THIS_BASE_BRANCH", configured_base()},
        {"AIUR_TICKET_BRANCH", ticket_branch()},
        {"AIUR_REPO_STATE_PATH", cache_root(workspace)}
      ]
    )
  end

  defp cache_root(workspace), do: Path.join(Path.dirname(workspace), "repo-state")
  defp git!(args), do: args |> then(&System.cmd(real_git(), &1, stderr_to_stdout: true)) |> elem(0)
  defp real_git, do: System.get_env("AIUR_REAL_GIT") || System.find_executable("git")
  defp fixture_path, do: Path.dirname(real_git()) <> ":/bin"
  defp configured_base, do: "stable"
  defp ticket_branch, do: "aiur/1054-test"
end
