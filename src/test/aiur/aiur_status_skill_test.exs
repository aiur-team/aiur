defmodule Aiur.AiurStatusSkillTest do
  @moduledoc """
  Guards #489: the `/aiur-status` gather script must discover the live aiur
  instance's actual workspaces under `~/.aiur/workspaces/<owner>/<repo>/<id>/`,
  not just the source repo's configured `workspace.root`. Before this fix the
  script tailed only the stale config root and reported "no active agents" while
  a background run was actively writing logs.

  The script is plain bash, so we drive it as a subprocess against a fixture
  HOME and assert on its stdout.
  """
  use ExUnit.Case, async: true

  # test/aiur/ -> test/ -> src/ -> repo root
  @repo_root Path.expand("../../..", __DIR__)
  @script Path.join(@repo_root, ".claude/skills/aiur-status/scripts/tail-agents.sh")

  setup do
    # Isolated fake HOME so `~/.aiur/workspaces` and `~/.aiur/logs` resolve into
    # a scratch tree we control, never the operator's real one.
    home = Path.join(System.tmp_dir!(), "aiur-status-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(home) end)
    {:ok, home: home}
  end

  # The regression fixture from #489: `.aiur/config` points workspace.root at
  # ~/code/aiur-workspaces, but the live run's workspaces live under the
  # owner-namespaced ~/.aiur/workspaces tree.
  defp build_fixture(home) do
    config = Path.join(home, "cfg")
    File.mkdir_p!(home)
    File.write!(config, "workspace:\n  root: ~/code/aiur-workspaces\n")

    # Configured root exists but is empty — the stale default.
    File.mkdir_p!(Path.join(home, "code/aiur-workspaces"))

    # Active namespaced workspace the live instance actually writes to.
    agent_log = Path.join(home, ".aiur/workspaces/its-applekid/actions/38/logs/agent.md")
    File.mkdir_p!(Path.dirname(agent_log))
    File.write!(agent_log, "## 2026-06-23T20:30:00Z item/started\n{\"method\":\"item/started\"}\n")

    config
  end

  # Runs the script with a fake HOME. `node_down?: true` shadows `pgrep`/`tmux`
  # on PATH with stubs that report nothing running, exercising the daemon-down
  # branch deterministically regardless of the host.
  defp run(config, home, opts \\ []) do
    env = [{"HOME", home}]

    env =
      if opts[:node_down?] do
        bin = Path.join(home, "bin")
        File.mkdir_p!(bin)

        for name <- ~w(pgrep tmux) do
          stub = Path.join(bin, name)
          File.write!(stub, "#!/bin/sh\nexit 1\n")
          File.chmod!(stub, 0o755)
        end

        [{"PATH", bin <> ":" <> System.get_env("PATH", "")} | env]
      else
        env
      end

    {out, status} = System.cmd("bash", [@script, config], env: env, stderr_to_stdout: true)
    assert status == 0, "script exited #{status}:\n#{out}"
    out
  end

  test "finds namespaced workspaces under ~/.aiur/workspaces when config root differs", %{
    home: home
  } do
    config = build_fixture(home)
    out = run(config, home)

    # The active agent is discovered despite living outside the config root,
    # and is attributed to the ~/.aiur/workspaces tree, not the config root.
    assert out =~ ~r{AGENT 38 .* root \S*\.aiur/workspaces}

    # And the script never reports the false negative from the issue.
    refute out =~ "no active agents"
  end

  test "surfaces a root mismatch warning when the config root is stale", %{home: home} do
    config = build_fixture(home)
    out = run(config, home)

    assert out =~ "warning:"
    assert out =~ "mismatch"
    assert out =~ "workspace.root is"
  end

  test "reports daemon down with last activity when the node is gone but logs are recent", %{
    home: home
  } do
    config = build_fixture(home)
    out = run(config, home, node_down?: true)

    assert out =~ "DAEMON node no"
    assert out =~ "daemon down"
    assert out =~ ~r/last activity \d+m ago/
    # Even with the node down, the recent agent is still listed, not swallowed.
    assert out =~ "AGENT 38"
  end
end
