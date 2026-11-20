defmodule Aiur.DogfoodHooksIdentityTest do
  use ExUnit.Case, async: true

  @hooks_path Path.expand("../../../.aiur/hooks", __DIR__)
  @external_resource @hooks_path

  setup do
    test_root = Aiur.TestSupport.tmp_root!("aiur-dogfood-hooks-identity")
    File.mkdir_p!(test_root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(test_root) end)

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
    git!(["-C", seed, "checkout", "--quiet", "-b", "stable"])
    File.write!(Path.join(seed, "README.md"), "stable one\n")
    git!(["-C", seed, "commit", "--quiet", "-am", "stable one"])
    git!(["-C", seed, "push", "--quiet", "-u", "origin", "stable"])

    {:ok, test_root: test_root, origin: origin, seed: seed}
  end

  test "before_run merge commit is authored by the agent, not the host's global git identity", context do
    workspace = Path.join(context.test_root, "merge-identity")
    File.mkdir_p!(workspace)
    {_, 0} = run_hook("after_create", workspace, context.origin)

    # A diverged branch forces a real merge commit.
    File.write!(Path.join(workspace, "ticket.txt"), "ticket\n")
    git!(["-C", workspace, "add", "ticket.txt"])
    git!(["-C", workspace, "-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", "ticket work"])
    File.write!(Path.join(context.seed, "README.md"), "stable two\n")
    git!(["-C", context.seed, "commit", "-am", "advance stable"])
    git!(["-C", context.seed, "push", "origin", "stable"])

    global = Path.join(context.test_root, "host-gitconfig")
    File.write!(global, "[user]\n\tname = Host Operator\n\temail = operator@host.test\n")

    {output, status} =
      run_hook("before_run", workspace, context.origin, [
        # The daemon's hook env carries no GIT_* identity; clear any inherited from the test host.
        {"GIT_AUTHOR_NAME", nil},
        {"GIT_AUTHOR_EMAIL", nil},
        {"GIT_COMMITTER_NAME", nil},
        {"GIT_COMMITTER_EMAIL", nil},
        {"GIT_CONFIG_GLOBAL", global},
        {"GIT_CONFIG_SYSTEM", "/dev/null"}
      ])

    assert status == 0, output

    assert git!(["-C", workspace, "log", "-1", "--merges", "--format=%an <%ae>|%cn <%ce>"]) ==
             "Hook Agent <hook-agent@example.test>|Hook Agent <hook-agent@example.test>\n"
  end

  defp run_hook(name, workspace, origin, extra_env \\ []) do
    {:ok, hooks} = YamlElixir.read_from_file(@hooks_path)

    System.cmd("sh", ["-c", Map.fetch!(hooks, name)],
      cd: workspace,
      stderr_to_stdout: true,
      env:
        [
          {"PATH", Path.dirname(real_git()) <> ":/bin"},
          {"THIS_REPOSITORY_URL", origin},
          {"THIS_BASE_BRANCH", "stable"},
          {"AIUR_TICKET_BRANCH", "aiur/1054-test"},
          {"AIUR_REPO_STATE_PATH", Path.join(Path.dirname(workspace), "repo-state")},
          {"AIUR_GIT_NAME", "Hook Agent"},
          {"AIUR_GIT_EMAIL", "hook-agent@example.test"}
        ] ++ extra_env
    )
  end

  defp git!(args) do
    {output, 0} = System.cmd(real_git(), args, stderr_to_stdout: true)
    output
  end

  defp real_git, do: System.get_env("AIUR_REAL_GIT") || System.find_executable("git")
end
