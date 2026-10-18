defmodule Aiur.AgentGitHubGuard.SecondaryLimitsTest do
  use Aiur.AgentGitHubGuardCase, async: true

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
                {"AIUR_GITHUB_BUDGET_ENABLED", "1"},
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

  test "the wrapper keeps one admission ledger when its publication token rotates", context do
    budget_root = Path.join(context.state_path, "rotating-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    identity_key = Budget.identity_key("machine_user:primary:aiur-bot")
    first_key = Budget.token_key("publication-token-a")
    second_key = Budget.token_key("publication-token-b")

    common = [
      AIUR_GITHUB_BUDGET_ROOT: budget_root,
      AIUR_GITHUB_BUDGET_BROKER: broker,
      AIUR_GITHUB_BUDGET_IDENTITY_KEY: identity_key,
      AIUR_GITHUB_STAGGER_MS: "0"
    ]

    assert {"ok\n", 0} = run_guard(context, ["api", "repos/owner/repo/issues/2236"], common ++ [AIUR_GITHUB_BUDGET_KEY: first_key])
    assert {"ok\n", 0} = run_guard(context, ["api", "repos/owner/repo/issues/2237"], common ++ [AIUR_GITHUB_BUDGET_KEY: second_key])

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", second_key, "--identity-key", identity_key])

    assert length(Jason.decode!(snapshot)["admissions"]) == 2
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

  test "a wrapper secondary cooldown blocks daemon requests for the same credential", context do
    budget_root = Path.join(context.state_path, "host-budget")
    credential = "preferred-gh-token"
    reset = System.os_time(:second) + 3_600

    assert {_output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_REPO_STATE_PATH: "",
               AIUR_AGENT_QUOTA_STATE_PATH: "",
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace),
               GH_TOKEN: credential,
               GITHUB_TOKEN: "different-github-token",
               FAKE_GH_FAIL: "1",
               FAKE_GH_ERROR: "HTTP 403: You have exceeded a secondary rate limit",
               FAKE_RATE_LIMIT: "4077 #{reset} 4405 #{reset}"
             )

    assert {:hold, %{reason: :shared_budget}} =
             Budget.acquire(
               %{method: :get, url: "https://api.github.com/repos/owner/repo/pulls/1670", token: credential},
               state_dir: budget_root,
               enabled?: true,
               max_inflight: 4,
               max_inflight_per_endpoint: 2,
               requests_per_minute: 20,
               stagger_ms: 0,
               timeout_ms: 1_000
             )

    assert {:ok, different_lease} =
             Budget.acquire(
               %{method: :get, url: "https://api.github.com/repos/owner/repo/pulls/1670", token: "different-github-token"},
               state_dir: budget_root,
               enabled?: true,
               max_inflight: 4,
               max_inflight_per_endpoint: 2,
               requests_per_minute: 20,
               stagger_ms: 0
             )

    assert :ok = Budget.release(different_lease, state_dir: budget_root, enabled?: true)
  end

  test "a nested guard path resolves the underlying gh binary once", context do
    nested_workspace = Path.join(Path.dirname(context.workspace), "1671")
    File.mkdir_p!(nested_workspace)
    :ok = AgentGitHubGuard.install(nested_workspace)

    assert {"ok\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_REAL_GH: Path.join(AgentGitHubGuard.bin_dir(nested_workspace), "gh"),
               PATH: "#{Path.dirname(context.fake_gh)}:#{System.get_env("PATH")}"
             )

    assert File.read!(context.calls) == "api repos/owner/repo/issues/1670\n"
  end

  test "a graphql resource hold blocks the GraphQL high-level read", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"", 0} =
             System.cmd("python3", [broker, "hold", "--scope", "resource", "--resource", "graphql", "--delay-ms", "60000", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    # `pr view` is GraphQL on the wire (#2302), so a GraphQL resource hold must
    # block it. A 60-second resource hold is above the shared-hold minimum, so
    # the guard aborts with exit 75 and names the resource for the control
    # lifecycle rather than sleeping the turn away.
    assert {output, 75} =
             System.cmd(context.wrapper, ["pr", "view", "1670"],
               env:
                 guard_env(context) ++
                   [
                     {"AIUR_GITHUB_BUDGET_ENABLED", "1"},
                     {"AIUR_GITHUB_BUDGET_ROOT", budget_root},
                     {"AIUR_GITHUB_BUDGET_KEY", key},
                     {"AIUR_GITHUB_BUDGET_BROKER", broker}
                   ],
               stderr_to_stdout: true
             )

    assert output =~ "aiur: github budget hold resource=graphql reset_at_ms="

    refute File.exists?(context.calls)
  end

  test "a core resource hold blocks a REST high-level command", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"", 0} =
             System.cmd("python3", [broker, "hold", "--scope", "resource", "--resource", "core", "--delay-ms", "60000", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    # `pr diff` is REST, so a core resource hold must block it — `pr view` is
    # GraphQL since #2302 and would be metered against the other pool.
    assert {output, 75} =
             System.cmd(context.wrapper, ["pr", "diff", "1670"],
               env:
                 guard_env(context) ++
                   [
                     {"AIUR_GITHUB_BUDGET_ENABLED", "1"},
                     {"AIUR_GITHUB_BUDGET_ROOT", budget_root},
                     {"AIUR_GITHUB_BUDGET_KEY", key},
                     {"AIUR_GITHUB_BUDGET_BROKER", broker}
                   ],
               stderr_to_stdout: true
             )

    assert output =~ "aiur: github budget hold resource=core reset_at_ms="

    refute File.exists?(context.calls)
  end

  test "a short cooldown keeps sleeping in the guard instead of pausing the turn", context do
    # A 2-second token cooldown is below the shared-hold minimum, so the broker
    # answers `wait <ms>` and the guard must sleep-and-retry in place — the same
    # behavior as before typed holds existed — rather than aborting with exit 75
    # and pausing the whole agent turn for a routine 60-second backoff.
    assert_token_cooldown_sleeps(context, 2000)
  end

  test "a 60-second token cooldown still sleeps in the guard instead of pausing the turn", context do
    # The broker's default secondary-rate-limit cooldown is 60 seconds and is
    # token-scoped (a routine self-backoff, not a real resource hold). It must
    # keep sleeping inside the guard's sleep-and-retry loop — the behavior that
    # existed before typed holds — rather than surfacing a `hold shared` that
    # aborts with exit 75 and pauses the agent's whole turn. The hold's
    # duration (60s) is irrelevant: token cooldowns never reach the control
    # lifecycle, only resource holds do.
    assert_token_cooldown_sleeps(context, 60_000)
  end

  # #4964: a `timeout 0.2` around a real 60s sleep hung the test past ExUnit's
  # 60s limit under load. A stub `sleep` records the guard's requested delay and
  # SIGKILLs the guard, so the decision is observed without any wall-clock race.
  defp assert_token_cooldown_sleeps(context, delay_ms) do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"", 0} =
             System.cmd("python3", [broker, "hold", "--scope", "token", "--delay-ms", "#{delay_ms}", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    bin = Path.join(context.tmp_dir, "stop-at-sleep")
    slept = Path.join(context.tmp_dir, "slept")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "sleep"), "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '#{slept}'\nkill -KILL \"$PPID\"\n")
    File.chmod!(Path.join(bin, "sleep"), 0o755)

    assert {output, 137} =
             run_guard(context, ["pr", "view", "1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               PATH: bin <> ":" <> System.get_env("PATH", "")
             )

    refute output =~ "aiur: github budget hold"
    assert [seconds] = slept |> File.read!() |> String.split("\n", trim: true)
    assert String.to_float(seconds) > 0 and String.to_float(seconds) <= delay_ms / 1000
    refute File.exists?(context.calls)
  end

  test "a guarded high-level command fails closed before native pagination can bypass admissions", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    for limit_args <- [["--limit", "1000"], ["--limit=1000"], ["-L1000"]] do
      assert {output, 64} =
               run_guard(context, ["pr", "list" | limit_args],
                 AIUR_GITHUB_BUDGET_ROOT: budget_root,
                 AIUR_GITHUB_BUDGET_KEY: key,
                 AIUR_GITHUB_BUDGET_BROKER: broker
               )

      assert output =~ "cannot fetch more than one page"
    end

    refute File.exists?(context.calls)

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => []} = Jason.decode!(snapshot)
  end

  test "a one-page high-level command retains its single guarded admission", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"ok\n", 0} =
             run_guard(context, ["pr", "list", "--limit", "100"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker
             )

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    # `pr list` is GraphQL on the wire but keeps the descriptive pulls family
    # (the lease-pool and audit key), so its single guarded admission books
    # resource=graphql while the family stays pulls.
    assert %{"admissions" => [%{"endpoint_family" => "pulls", "resource" => "graphql"}]} = Jason.decode!(snapshot)
  end
end
