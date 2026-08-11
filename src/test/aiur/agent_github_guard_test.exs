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
      sleep "${FAKE_GH_SLEEP:-0}"
      if [ "${FAKE_GH_FAIL:-0}" = 1 ]; then printf '%s\n' "${FAKE_GH_ERROR:-failed}" >&2; exit 1; fi
      printf 'ok\n'
      """
    )

    File.chmod!(fake_gh, 0o755)
    :ok = AgentGitHubGuard.install(workspace)

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, wrapper: Path.join(AgentGitHubGuard.bin_dir(workspace), "gh"), workspace: workspace, state_path: state_path, fake_gh: fake_gh, calls: calls}
  end

  test "installs the companion host-budget broker alongside the gh wrapper", context do
    assert File.regular?(AgentGitHubGuard.budget_broker_path(context.workspace))
    assert File.stat!(AgentGitHubGuard.budget_broker_path(context.workspace)).mode |> Bitwise.band(0o111) != 0
  end

  test "records ticket-shaped read and write attribution without command arguments", context do
    assert {"ok\n", 0} = run_guard(context, ["issue", "view", "1670"])
    assert {"ok\n", 0} = run_guard(context, ["issue", "edit", "1670", "--body", "secret body"])

    events = File.read!(Path.join(context.state_path, "github-quota/agent-requests.tsv"))
    assert events =~ "\tticket:1670\tread\tcore\n"
    assert events =~ "\tticket:1670\twrite\tcore\n"
    refute events =~ "secret body"
  end

  # GraphQL is billed in points against its own budget. A row that does not say
  # which budget it spent gets counted against core, putting agent GraphQL
  # traffic in the wrong window (#1805).
  test "names the budget each recorded call was billed to", context do
    assert {"ok\n", 0} = run_guard(context, ["api", "graphql", "-f", "query=query { viewer { login } }"])
    assert {"ok\n", 0} = run_guard(context, ["api", "repos/owner/repo/issues"])

    events = File.read!(Path.join(context.state_path, "github-quota/agent-requests.tsv"))
    assert events =~ "\tread\tgraphql\n"
    assert events =~ "\tread\tcore\n"
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

  # The field failure: `gh` refused with a rate-limit error while both primary
  # windows still read healthy. Without a secondary hold the guard recorded
  # nothing and the next call went straight back out.
  test "a rate-limit failure with healthy primary windows records a secondary backoff", context do
    reset = System.os_time(:second) + 3600
    before = System.os_time(:second)

    assert {output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues"],
               FAKE_GH_FAIL: "1",
               FAKE_GH_ERROR: "HTTP 403: You have exceeded a secondary rate limit",
               FAKE_RATE_LIMIT: "4077 #{reset} 4405 #{reset}"
             )

    assert output =~ "secondary rate limit"

    quota_dir = Path.join(context.state_path, "github-quota")
    refute File.exists?(Path.join(quota_dir, "core-hold"))

    held_until = quota_dir |> Path.join("core-secondary-hold") |> File.read!() |> String.trim() |> String.to_integer()
    assert held_until >= before + 60
    assert held_until <= System.os_time(:second) + 60
  end

  test "a secondary hold prevents an immediate retry of the real gh command", context do
    hold_file = Path.join(context.state_path, "github-quota/core-secondary-hold")
    File.mkdir_p!(Path.dirname(hold_file))
    File.write!(hold_file, "#{System.os_time(:second) + 60}\n")

    timeout = System.find_executable("timeout") || flunk("timeout executable is required for this Linux-only guard test")
    {_output, 124} = System.cmd(timeout, ["0.2", context.wrapper, "api", "repos/owner/repo/issues/1670"], env: guard_env(context), stderr_to_stdout: true)

    refute File.exists?(context.calls)
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

  test "separate agent workspaces share the host in-flight ceiling", context do
    other_workspace = Path.join(Path.dirname(context.workspace), "1671")
    File.mkdir_p!(other_workspace)
    :ok = AgentGitHubGuard.install(other_workspace)

    budget_root = Path.join(context.state_path, "host-budget")

    first =
      Task.async(fn ->
        run_guard(context, ["api", "repos/owner/repo/issues/1670"],
          AIUR_GITHUB_BUDGET_ROOT: budget_root,
          AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
          AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace),
          AIUR_GITHUB_MAX_INFLIGHT: "1",
          AIUR_GITHUB_MAX_INFLIGHT_PER_ENDPOINT: "1",
          AIUR_GITHUB_REQUESTS_PER_MINUTE: "20",
          AIUR_GITHUB_STAGGER_MS: "0",
          FAKE_GH_SLEEP: "0.3"
        )
      end)

    wait_for_calls(context.calls, 1)

    second =
      Task.async(fn ->
        System.cmd(Path.join(AgentGitHubGuard.bin_dir(other_workspace), "gh"), ["api", "repos/owner/repo/issues/1671"],
          env:
            guard_env(context) ++
              [
                {"AIUR_AGENT_WORKSPACE", other_workspace},
                {"AIUR_GITHUB_BUDGET_ROOT", budget_root},
                {"AIUR_GITHUB_BUDGET_KEY", "a" <> String.duplicate("0", 63)},
                {"AIUR_GITHUB_BUDGET_BROKER", AgentGitHubGuard.budget_broker_path(other_workspace)},
                {"AIUR_GITHUB_MAX_INFLIGHT", "1"},
                {"AIUR_GITHUB_MAX_INFLIGHT_PER_ENDPOINT", "1"},
                {"AIUR_GITHUB_REQUESTS_PER_MINUTE", "20"},
                {"AIUR_GITHUB_STAGGER_MS", "0"}
              ],
          stderr_to_stdout: true
        )
      end)

    assert Task.yield(second, 80) == nil
    assert {"ok\n", 0} = Task.await(first, 1_500)
    assert {"ok\n", 0} = Task.await(second, 1_500)
  end

  test "an Executor-style gh wrapper publishes a secondary cooldown to the host budget", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)
    reset = System.os_time(:second) + 3_600

    assert {output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_REPO_STATE_PATH: "",
               AIUR_AGENT_QUOTA_STATE_PATH: "",
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               FAKE_GH_FAIL: "1",
               FAKE_GH_ERROR: "HTTP 403: You have exceeded a secondary rate limit",
               FAKE_RATE_LIMIT: "4077 #{reset} 4405 #{reset}"
             )

    assert output =~ "secondary rate limit"

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"cooldown_until_ms" => cooldown_until} = Jason.decode!(snapshot)
    assert cooldown_until >= System.os_time(:millisecond) + 59_000
  end

  test "an Executor-style wrapper honours Retry-After in its shared cooldown", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)
    reset = System.os_time(:second) + 3_600

    assert {_output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_REPO_STATE_PATH: "",
               AIUR_AGENT_QUOTA_STATE_PATH: "",
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               FAKE_GH_FAIL: "1",
               FAKE_GH_ERROR: "HTTP 403: You have exceeded a secondary rate limit\nRetry-After: 2",
               FAKE_RATE_LIMIT: "4077 #{reset} 4405 #{reset}"
             )

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"cooldown_until_ms" => cooldown_until} = Jason.decode!(snapshot)
    # The wrapper command and SQLite snapshot consume a small part of the
    # advertised two-second window; keep enough margin for a loaded host while
    # still distinguishing Retry-After from the 60-second fallback.
    assert cooldown_until >= System.os_time(:millisecond) + 1_500
    assert cooldown_until <= System.os_time(:millisecond) + 3_000
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
      {"AIUR_AGENT_QUOTA_STATE_PATH", ""},
      {"AIUR_AGENT_WORKSPACE", context.workspace},
      {"FAKE_GH_CALLS", context.calls},
      {"GITHUB_TOKEN", ""},
      {"AIUR_GITHUB_BUDGET_ROOT", ""},
      {"AIUR_GITHUB_BUDGET_KEY", ""},
      {"AIUR_GITHUB_BUDGET_BROKER", "/nonexistent/aiur-github-budget"}
    ]
  end

  defp wait_for_calls(path, expected, attempts \\ 50)

  defp wait_for_calls(_path, _expected, 0), do: flunk("timed out waiting for guarded gh call")

  defp wait_for_calls(path, expected, attempts) do
    calls =
      case File.read(path) do
        {:ok, contents} -> String.split(contents, "\n", trim: true) |> length()
        _missing -> 0
      end

    if calls >= expected do
      :ok
    else
      Process.sleep(10)
      wait_for_calls(path, expected, attempts - 1)
    end
  end
end
