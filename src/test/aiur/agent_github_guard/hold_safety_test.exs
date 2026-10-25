defmodule Aiur.AgentGitHubGuard.HoldSafetyTest do
  # #4698: a guard test run published a 30-day graphql-secondary-hold into the
  # live host quota dir and parked every agent. These pin the three defenses.
  use Aiur.AgentGitHubGuardCase, async: true

  @thirty_days 30 * 86_400
  @secondary_failure [
    FAKE_GH_FAIL: "1",
    FAKE_GH_ERROR: "HTTP 403: You have exceeded a secondary rate limit"
  ]

  defp tree_digest(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.sort()
    |> Enum.map(fn path -> {Path.relative_to(path, root), if(File.regular?(path), do: :crypto.hash(:sha256, File.read!(path)), else: :dir)} end)
  end

  test "empty state paths never publish into the host ~/.aiur quota dir", context do
    home = Path.join(context.tmp_dir, "home")
    canary = Path.join(home, ".aiur/repo/aiur-team/aiur/github-quota")
    File.mkdir_p!(canary)
    File.write!(Path.join(canary, "agent-requests.tsv"), "canary\n")
    before = tree_digest(Path.join(home, ".aiur/repo"))
    reset = System.os_time(:second) + 3_600

    empty_paths = [AIUR_REPO_STATE_PATH: "", AIUR_AGENT_QUOTA_STATE_PATH: "", HOME: home, FAKE_RATE_LIMIT: "4077 #{reset} 4405 #{reset}"]
    budget = [AIUR_GITHUB_BUDGET_ROOT: Path.join(context.state_path, "host-budget"), AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace)]

    # The two SecondaryLimitsTest cases the incident traced to, plus the GraphQL resource path.
    assert {output, 1} = run_guard(context, ["api", "repos/owner/repo/issues/1670"], empty_paths ++ budget ++ [AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63)] ++ @secondary_failure)
    assert output =~ "secondary rate limit"
    assert {_output, 1} = run_guard(context, ["api", "repos/owner/repo/issues/1670"], empty_paths ++ budget ++ [GH_TOKEN: "preferred-gh-token"] ++ @secondary_failure)
    assert {output, 1} = run_guard(context, ["api", "graphql", "-f", "query=query { viewer { login } }"], empty_paths ++ @secondary_failure)
    assert output =~ "secondary rate limit"

    assert tree_digest(Path.join(home, ".aiur/repo")) == before
    assert Path.wildcard(Path.join(home, "**/*-hold"), match_dot: true) == []
  end

  test "the guard refuses to publish a hold more than an hour ahead", context do
    quota_dir = Path.join(context.state_path, "github-quota")
    far = System.os_time(:second) + @thirty_days

    assert {output, 1} = run_guard(context, ["api", "repos/owner/repo/issues"], @secondary_failure ++ [FAKE_RATE_LIMIT: "0 #{far} 0 #{far}"])
    assert output =~ "refusing implausible core-hold"
    assert output =~ "refusing implausible graphql-hold"
    refute File.exists?(Path.join(quota_dir, "core-hold"))
    refute File.exists?(Path.join(quota_dir, "graphql-hold"))

    # Control: a real exhausted window still publishes its hold.
    near = System.os_time(:second) + 120
    assert {_output, 1} = run_guard(context, ["api", "repos/owner/repo/issues"], @secondary_failure ++ [FAKE_RATE_LIMIT: "0 #{near} 4405 #{near}"])
    assert File.read!(Path.join(quota_dir, "core-hold")) == "#{near}\n"
  end

  test "a month-long Retry-After is clamped to an hour", context do
    reset = System.os_time(:second) + 3_600

    assert {_output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: Path.join(context.state_path, "host-budget"),
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace),
               FAKE_GH_FAIL: "1",
               FAKE_GH_ERROR: "HTTP 403: request rejected",
               FAKE_GH_INCLUDE_HEADERS: "1",
               FAKE_GH_HEADERS: "HTTP/2 403\nRetry-After: #{@thirty_days}\n\n",
               FAKE_RATE_LIMIT: "4077 #{reset} 4405 #{reset}"
             )

    held_until = context.state_path |> Path.join("github-quota/core-secondary-hold") |> File.read!() |> String.trim() |> String.to_integer()
    assert held_until <= System.os_time(:second) + 3_600
    assert held_until >= System.os_time(:second) + 3_500
  end

  test "a hold more than an hour ahead is ignored, not slept on", context do
    hold_file = Path.join(context.state_path, "github-quota/graphql-secondary-hold")
    File.mkdir_p!(Path.dirname(hold_file))
    File.write!(hold_file, "#{System.os_time(:second) + @thirty_days}\n")

    timeout = System.find_executable("timeout") || flunk("timeout executable is required for this Linux-only guard test")
    assert {output, 0} = System.cmd(timeout, ["5", context.wrapper, "api", "graphql", "-f", "query=query { viewer { login } }"], env: guard_env(context), stderr_to_stdout: true)

    assert output =~ "ignoring implausible hold"
    assert output =~ "ok"
    # Removal and the alert are the daemon's job (`Aiur.GitHub.HoldSweep`).
    assert File.exists?(hold_file)
  end
end
