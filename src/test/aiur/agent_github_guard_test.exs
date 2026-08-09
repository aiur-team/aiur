defmodule Aiur.AgentGitHubGuardTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentGitHubGuard

  setup do
    root = Path.join(System.tmp_dir!(), "aiur-github-guard-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "1670")
    state_path = Path.join(root, "state")
    fake_gh = Path.join(root, "real-gh")
    calls = Path.join(root, "calls")
    File.mkdir_p!(workspace)

    File.write!(
      fake_gh,
      """
      #!/bin/sh
      if [ "${1:-} ${2:-}" = "api rate_limit" ]; then
        printf '%s' "${FAKE_RATE_LIMIT:-5000 0 5000 0}"
        exit 0
      fi
      printf '%s %s\n' "${1:-}" "${2:-}" >> "$FAKE_GH_CALLS"
      if [ "${FAKE_GH_FAIL:-0}" = 1 ]; then printf '%s\n' "${FAKE_GH_ERROR:-failed}" >&2; exit 1; fi
      printf 'ok\n'
      """
    )

    File.chmod!(fake_gh, 0o755)
    :ok = AgentGitHubGuard.install(workspace)

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, wrapper: Path.join(AgentGitHubGuard.bin_dir(workspace), "gh"), workspace: workspace, state_path: state_path, fake_gh: fake_gh, calls: calls}
  end

  test "records ticket-shaped read and write attribution without command arguments", context do
    assert {"ok\n", 0} = run_guard(context, ["issue", "view", "1670"])
    assert {"ok\n", 0} = run_guard(context, ["issue", "edit", "1670", "--body", "secret body"])

    events = File.read!(Path.join(context.state_path, "github-quota/agent-requests.tsv"))
    assert events =~ "\tticket:1670\tread\n"
    assert events =~ "\tticket:1670\twrite\n"
    refute events =~ "secret body"
  end

  test "an ordinary failed call does not create quota holds or probe the API", context do
    assert {_output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues"], FAKE_GH_FAIL: "1")

    refute File.exists?(Path.join(context.state_path, "github-quota/core-hold"))
    refute File.read!(context.calls) =~ "api rate_limit"
  end

  test "a rate-limit failure records exact resource reset holds", context do
    reset = System.os_time(:second) + 3600

    assert {_output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues"],
               FAKE_GH_FAIL: "1",
               FAKE_GH_ERROR: "HTTP 403: API rate limit exceeded",
               FAKE_RATE_LIMIT: "0 #{reset} 5000 #{reset}"
             )

    assert File.read!(Path.join(context.state_path, "github-quota/core-hold")) == "#{reset}\n"
    refute File.exists?(Path.join(context.state_path, "github-quota/graphql-hold"))
  end

  test "a retained hold prevents the real gh command from being retried immediately", context do
    hold_file = Path.join(context.state_path, "github-quota/core-hold")
    File.mkdir_p!(Path.dirname(hold_file))
    File.write!(hold_file, "#{System.os_time(:second) + 60}\n")

    timeout = System.find_executable("timeout") || flunk("timeout executable is required for this Linux-only guard test")
    {_output, 124} = System.cmd(timeout, ["0.2", context.wrapper, "api", "repos/owner/repo/issues/1670"], env: guard_env(context), stderr_to_stdout: true)

    refute File.exists?(context.calls)
  end

  test "a core hold does not block an explicitly GraphQL command", context do
    hold_file = Path.join(context.state_path, "github-quota/core-hold")
    File.mkdir_p!(Path.dirname(hold_file))
    File.write!(hold_file, "#{System.os_time(:second) + 60}\n")

    assert {"ok\n", 0} = run_guard(context, ["api", "graphql", "-f", "query=query { viewer { login } }"])
  end

  test "a local gh command bypasses active API holds", context do
    quota_dir = Path.join(context.state_path, "github-quota")
    File.mkdir_p!(quota_dir)
    File.write!(Path.join(quota_dir, "core-hold"), "#{System.os_time(:second) + 60}\n")
    File.write!(Path.join(quota_dir, "graphql-hold"), "#{System.os_time(:second) + 60}\n")

    assert {"ok\n", 0} = run_guard(context, ["version"])
  end

  test "installer rejects symlinked runtime directories", context do
    runtime = Path.join(context.workspace, ".aiur-runtime")
    external = Path.join(Path.dirname(context.workspace), "outside")
    File.rm_rf!(runtime)
    File.mkdir_p!(external)
    File.ln_s!(external, runtime)

    assert {:error, {:unsafe_agent_support_path, ^runtime, :symlink}} =
             AgentGitHubGuard.install(context.workspace)

    refute File.exists?(Path.join(external, "bin/gh"))
  end

  defp run_guard(context, args, extra_env \\ []) do
    System.cmd(context.wrapper, args,
      env: guard_env(context) ++ Enum.map(extra_env, fn {key, value} -> {Atom.to_string(key), value} end),
      stderr_to_stdout: true
    )
  end

  defp guard_env(context) do
    [
      {"AIUR_REAL_GH", context.fake_gh},
      {"AIUR_REPO_STATE_PATH", context.state_path},
      {"AIUR_AGENT_WORKSPACE", context.workspace},
      {"FAKE_GH_CALLS", context.calls}
    ]
  end
end
