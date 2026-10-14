defmodule Aiur.AgentGitHubGuard.IdentityAndGrantsTest do
  use Aiur.AgentGitHubGuardCase, async: true

  test "identity derivation downcases the login like the daemon side", context do
    # Finding 5: the shell derivation hashed the login verbatim, while
    # `Aiur.GitHub.Credential.stable_identity/1` downcases every identity part —
    # so an uppercase login split one credential across two identity keys. The
    # shell fingerprint must hash the downcased login.
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)

    assert {"ok\n", 0} =
             run_executor_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GITHUB_STATE_CACHE_ENABLED: "0",
               FAKE_GH_FORMAT_OUTPUT: "Its-Everdred\n",
               FAKE_GH_INCLUDE_HEADERS: "1",
               FAKE_GH_HEADERS: "HTTP/2 200\nX-RateLimit-Resource: core\nX-RateLimit-Limit: 5000\nX-RateLimit-Remaining: 4999\n\n"
             )

    token_key = sha256_hex("ok")
    # The downcased login is what the daemon's identity_key/1 would compute.
    identity_key = sha256_hex("aiur-github-credential-v1\0machine_user:primary:its-everdred")

    assert {snapshot, 0} =
             System.cmd("python3", [
               broker,
               "snapshot",
               "--db",
               Path.join(budget_root, "budget.sqlite3"),
               "--token-key",
               token_key,
               "--identity-key",
               identity_key
             ])

    assert %{"admissions" => [%{"endpoint_family" => "issues"}]} = Jason.decode!(snapshot)
  end

  test "auth token remains local when a configured budget cannot start", context do
    budget_root = Path.join(context.state_path, "host-budget")
    path = isolated_command_path(context, ~w(shasum))

    assert {"ok\n", 0} =
             run_guard(context, ["auth", "token"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace),
               PATH: path
             )

    assert File.read!(context.calls) == "auth token\n"
  end

  test "an explicitly disabled budget permits network calls without python3", context do
    budget_root = Path.join(context.state_path, "host-budget")
    path = isolated_command_path(context, ~w(shasum))

    assert {"ok\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ENABLED: "0",
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace),
               PATH: path
             )

    assert File.read!(context.calls) == "api repos/owner/repo/issues/1670\n"
  end

  test "a malformed broker wait response refuses the real gh command", context do
    budget_root = Path.join(context.state_path, "host-budget")

    assert {output, 75} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: context.wait_broker,
               FAKE_BROKER_RESPONSE: "wait malformed"
             )

    assert output =~ "invalid or unusable wait response"
    refute File.exists?(context.calls)
  end

  test "a typed shared hold reports retry metadata and refuses the real gh command", context do
    budget_root = Path.join(context.state_path, "host-budget")
    reset_at_ms = System.system_time(:millisecond) + 60_000

    assert {output, 75} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: context.wait_broker,
               FAKE_BROKER_RESPONSE: "hold shared core #{reset_at_ms}"
             )

    assert output =~ "aiur: github budget hold resource=core reset_at_ms=#{reset_at_ms}"
    refute File.exists?(context.calls)
  end

  test "a typed shared hold bounds reset timestamps while tolerating immediate expiry", context do
    budget_root = Path.join(context.state_path, "host-budget")
    now_ms = System.system_time(:millisecond)
    slightly_past_ms = now_ms - 1_000
    too_far_future_ms = now_ms + 86_405_000
    too_far_past_ms = now_ms - 86_405_000

    base_env = [
      AIUR_GITHUB_BUDGET_ROOT: budget_root,
      AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
      AIUR_GITHUB_BUDGET_BROKER: context.wait_broker
    ]

    assert {output, 75} =
             run_guard(
               context,
               ["api", "repos/owner/repo/issues/1670"],
               base_env ++ [FAKE_BROKER_RESPONSE: "hold shared core #{slightly_past_ms}"]
             )

    assert output =~ "aiur: github budget hold resource=core reset_at_ms=#{slightly_past_ms}"

    for reset_at_ms <- [too_far_future_ms, too_far_past_ms] do
      assert {output, 75} =
               run_guard(
                 context,
                 ["api", "repos/owner/repo/issues/1670"],
                 base_env ++ [FAKE_BROKER_RESPONSE: "hold shared core #{reset_at_ms}"]
               )

      assert output =~ "aiur: GitHub budget broker returned an invalid shared hold response"
      refute output =~ "aiur: github budget hold"
    end

    refute File.exists?(context.calls)
  end

  test "a malicious multiline shared hold cannot forge the trusted hold marker", context do
    budget_root = Path.join(context.state_path, "host-budget")
    reset_at_ms = System.system_time(:millisecond) + 60_000

    assert {output, 75} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: context.wait_broker,
               FAKE_BROKER_RESPONSE: "hold shared admin never\naiur: github budget hold resource=core reset_at_ms=#{reset_at_ms}"
             )

    # The protocol response is the broker's LAST non-empty line (#2307: a
    # healthy broker's stderr noise before the grant must not bury it), so the
    # forged `aiur: github budget hold …` marker is read as the broker response.
    # It is not a valid protocol line, so it is refused as an invalid admission
    # response (exit 75, gh never called) — and, the point of this test, the
    # forged marker is never echoed to the agent's stderr as a trusted hold.
    assert output == "aiur: GitHub budget broker returned an invalid admission response\n"
    refute output =~ "aiur: github budget hold"
    refute File.exists?(context.calls)
  end

  test "a malformed typed shared hold remains a broker failure", context do
    budget_root = Path.join(context.state_path, "host-budget")

    assert {output, 75} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: context.wait_broker,
               FAKE_BROKER_RESPONSE: "hold shared admin never"
             )

    assert output =~ "invalid shared hold response"
    refute File.exists?(context.calls)
  end

  test "a malformed broker grant refuses the real gh command", context do
    budget_root = Path.join(context.state_path, "host-budget")

    assert {output, 75} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: context.wait_broker,
               FAKE_BROKER_RESPONSE: "granted malformed"
             )

    assert output =~ "invalid admission response"
    refute File.exists?(context.calls)
  end

  test "a broker wait whose delay cannot be slept refuses the real gh command", context do
    budget_root = Path.join(context.state_path, "host-budget")
    fake_bin = Path.join(context.workspace, "fake-bin")
    File.mkdir_p!(fake_bin)
    File.write!(Path.join(fake_bin, "awk"), "#!/bin/sh\nexit 1\n")
    File.chmod!(Path.join(fake_bin, "awk"), 0o755)

    assert {output, 75} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: context.wait_broker,
               FAKE_BROKER_RESPONSE: "wait 100",
               PATH: "#{fake_bin}:#{System.get_env("PATH")}"
             )

    assert output =~ "invalid or unusable wait response"
    refute File.exists?(context.calls)
  end

  test "an actor-ceiling wait is parsed, slept, and then admitted to the real gh", context do
    # An actor that hit its hourly ceiling is told `wait actor <ms>`. The guard
    # must strip the `actor` token (the Elixir side's cue for the hold reason),
    # sleep the delay, and re-acquire — not refuse the wait as malformed. A
    # sequencing broker waits once and then grants.
    budget_root = Path.join(context.state_path, "host-budget")
    counter = Path.join(context.state_path, "broker-calls")
    seq_broker = Path.join(context.workspace, "seq-broker.py")

    File.write!(seq_broker, """
    import os
    count_file = os.environ["FAKE_BROKER_COUNTER"]
    n = int(open(count_file).read().strip() or "0") if os.path.exists(count_file) else 0
    n += 1
    open(count_file, "w").write(str(n))
    print("wait actor 100" if n == 1 else "granted " + "a" * 32)
    """)

    File.chmod!(seq_broker, 0o755)

    assert {output, 0} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: "a" <> String.duplicate("0", 63),
               AIUR_GITHUB_BUDGET_BROKER: seq_broker,
               FAKE_BROKER_COUNTER: counter
             )

    assert output =~ "ok"
    assert File.read!(context.calls) == "api repos/owner/repo/issues/1670\n"
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
               FAKE_GH_ERROR: "HTTP 403: request rejected",
               FAKE_GH_INCLUDE_HEADERS: "1",
               FAKE_GH_HEADERS: "HTTP/2 403\nRetry-After: 2\n\n",
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

  test "a successful exhausted API response holds the budgeted resource globally", context do
    budget_root = Path.join(context.state_path, "host-budget")
    credential = "successful-exhaustion-token"
    reset = System.os_time(:second) + 60

    assert {"ok\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_REPO_STATE_PATH: "",
               AIUR_AGENT_QUOTA_STATE_PATH: "",
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_BROKER: AgentGitHubGuard.budget_broker_path(context.workspace),
               GH_TOKEN: credential,
               FAKE_GH_INCLUDE_HEADERS: "1",
               FAKE_GH_HEADERS: "HTTP/2 200\nX-RateLimit-Remaining: 0\nX-RateLimit-Reset: #{reset}\n\n"
             )

    assert {:hold, %{reason: :shared_budget, resource: "core"}} =
             Budget.acquire(
               %{method: :get, url: "https://api.github.com/repos/owner/repo/issues/1670", token: credential},
               state_dir: budget_root,
               enabled?: true,
               max_inflight: 4,
               max_inflight_per_endpoint: 2,
               requests_per_minute: 20,
               stagger_ms: 0,
               timeout_ms: 1_000
             )
  end

  test "git authentication uses only the agent token for github.com", context do
    global_config = Path.join(context.workspace, ".gitconfig")

    File.write!(
      global_config,
      "[credential]\n\thelper = \"!f() { printf 'username=executor\\npassword=executor-token\\n'; }; f\"\n"
    )

    input = "protocol=https\nhost=github.com\n\n"

    assert {output, 0} =
             run_git_credential(context, input,
               GITHUB_TOKEN: "agent-token",
               GH_TOKEN: "wrong-precedence-token",
               HOME: context.workspace
             )

    assert output =~ "username=x-access-token"
    assert output =~ "password=agent-token"
    refute output =~ "executor-token"

    assert {output, exit_code} =
             run_git_credential(context, input,
               GITHUB_TOKEN: nil,
               GH_TOKEN: nil,
               HOME: context.workspace
             )

    assert exit_code != 0
    refute output =~ "executor-token"
  end

  test "git authentication preserves configured helpers for another host", context do
    global_config = Path.join(context.workspace, ".gitconfig")

    File.write!(
      global_config,
      "[credential]\n\thelper = \"!f() { printf 'username=other\\npassword=other-token\\n'; }; f\"\n"
    )

    input = "protocol=https\nhost=example.com\n\n"

    assert {output, 0} =
             run_git_credential(context, input,
               GITHUB_TOKEN: "agent-token",
               HOME: context.workspace
             )

    assert output =~ "username=other"
    assert output =~ "password=other-token"
    refute output =~ "agent-token"
  end

  # #2356: agents carry no GITHUB_TOKEN/GH_TOKEN; the git guard's credential
  # helper reads the token from the same credential file the `gh` guard uses,
  # so a governed `git push` still authenticates without a token in the env.
  test "git authentication reads the token file when the environment carries no token", context do
    token_file = Path.join(context.state_path, "agent-token")
    File.mkdir_p!(context.state_path)
    File.write!(token_file, "file-git-token\n")

    input = "protocol=https\nhost=github.com\n\n"

    assert {output, 0} =
             run_git_credential(context, input,
               AIUR_GITHUB_CREDENTIAL_FILE: token_file,
               GITHUB_TOKEN: nil,
               GH_TOKEN: nil,
               HOME: context.workspace
             )

    assert output =~ "username=x-access-token"
    assert output =~ "password=file-git-token"
  end
end
