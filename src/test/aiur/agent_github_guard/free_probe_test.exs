defmodule Aiur.AgentGitHubGuard.FreeProbeTest do
  use Aiur.AgentGitHubGuardCase, async: true

  test "failed request probes rate limits without waiting on its exhausted core ceiling", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)
    reset = System.os_time(:second) + 3_600
    timeout = System.find_executable("timeout") || flunk("timeout executable is required")

    assert {output, 1} =
             System.cmd(timeout, ["5", context.wrapper, "api", "repos/owner/repo/issues/1670"],
               env:
                 guard_env(context) ++
                   [
                     {"AIUR_REPO_STATE_PATH", ""},
                     {"AIUR_AGENT_QUOTA_STATE_PATH", ""},
                     {"AIUR_GITHUB_BUDGET_ENABLED", "1"},
                     {"AIUR_GITHUB_BUDGET_ROOT", budget_root},
                     {"AIUR_GITHUB_BUDGET_KEY", key},
                     {"AIUR_GITHUB_BUDGET_BROKER", broker},
                     {"AIUR_GITHUB_BUDGET_CONSUMER", "workspace:/exhausted-probe"},
                     {"AIUR_GITHUB_CORE_LIMIT_PER_HOUR", "1"},
                     {"AIUR_GITHUB_STAGGER_MS", "0"},
                     {"FAKE_GH_FAIL", "1"},
                     {"FAKE_GH_ERROR", "HTTP 403: API rate limit exceeded"},
                     {"FAKE_RATE_LIMIT", "4077 #{reset} 4405 #{reset}"}
                   ],
               stderr_to_stdout: true
             )

    assert output =~ "HTTP 403"

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => admissions} = Jason.decode!(snapshot)

    assert Enum.map(admissions, &{&1["endpoint_family"], &1["resource"], &1["billable"]}) ==
             [{"issues", "core", true}, {"rate_limit", "none", false}]
  end
end
