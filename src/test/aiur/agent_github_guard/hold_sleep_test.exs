defmodule Aiur.AgentGitHubGuard.HoldSleepTest do
  use Aiur.AgentGitHubGuardCase, async: true

  test "a non-billable rate_limit probe still consumes a rate-per-minute pacing slot", context do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"5000 0 5000 0", 0} =
             run_guard(context, ["api", "rate_limit"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GITHUB_REQUESTS_PER_MINUTE: "1",
               AIUR_GITHUB_STAGGER_MS: "0"
             )

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert %{"admissions" => [%{"endpoint_family" => "rate_limit", "billable" => false}]} = Jason.decode!(snapshot)

    assert String.starts_with?(
             run_held_guard(context, ["api", "repos/owner/repo/issues/1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GITHUB_REQUESTS_PER_MINUTE: "1",
               AIUR_GITHUB_STAGGER_MS: "0"
             ),
             "wait "
           )

    refute File.exists?(context.calls)
  end

  test "a short token cooldown sleeps in the guard rather than pausing the turn", context do
    assert_token_wait(context, "2000")
  end

  test "a 60-second token cooldown sleeps in the guard rather than pausing the turn", context do
    assert_token_wait(context, "60000")
  end

  test "TERM interrupts an active broker hold sleep", context do
    budget_root = Path.join(context.state_path, "term-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)
    sleep_pid_file = Path.join(context.state_path, "active-sleep-pid")
    sleep_bin = Path.join(context.state_path, "term-sleep-bin")
    File.mkdir_p!(sleep_bin)

    sleep = Path.join(sleep_bin, "sleep")

    File.write!(sleep, """
    #!/bin/sh
    printf '%s\\n' "$$" > "$FAKE_SLEEP_PID_FILE"
    exec /bin/sleep "$@"
    """)

    File.chmod!(sleep, 0o755)

    assert {"", 0} =
             System.cmd("python3", [broker, "hold", "--scope", "token", "--delay-ms", "60000", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    env =
      guard_env(context) ++
        [
          {"AIUR_GITHUB_BUDGET_ENABLED", "1"},
          {"AIUR_GITHUB_BUDGET_ROOT", budget_root},
          {"AIUR_GITHUB_BUDGET_KEY", key},
          {"AIUR_GITHUB_BUDGET_BROKER", broker},
          {"PATH", "#{sleep_bin}:#{System.get_env("PATH")}"},
          {"FAKE_SLEEP_PID_FILE", sleep_pid_file}
        ]

    port =
      Port.open({:spawn_executable, context.wrapper}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: Enum.map(["pr", "view", "1670"], &String.to_charlist/1),
        env: Enum.map(env, fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)
      ])

    {:os_pid, guard_pid} = Port.info(port, :os_pid)
    on_exit(fn -> stop_process(guard_pid) end)
    wait_until(fn -> File.exists?(sleep_pid_file) end)
    sleep_pid = File.read!(sleep_pid_file) |> String.trim()
    on_exit(fn -> stop_process(String.to_integer(sleep_pid)) end)

    assert {"", 0} = System.cmd("kill", ["-TERM", Integer.to_string(guard_pid)])
    assert_receive {^port, {:exit_status, 143}}, 2_000
    assert {_, 1} = System.cmd("kill", ["-0", sleep_pid], stderr_to_stdout: true)
  end

  defp assert_token_wait(context, delay_ms) do
    budget_root = Path.join(context.state_path, "host-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    key = "a" <> String.duplicate("0", 63)

    assert {"", 0} =
             System.cmd("python3", [broker, "hold", "--scope", "token", "--delay-ms", delay_ms, "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

    assert String.starts_with?(
             run_held_guard(context, ["pr", "view", "1670"],
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: key,
               AIUR_GITHUB_BUDGET_BROKER: broker
             ),
             "wait "
           )

    refute File.exists?(context.calls)
  end

  defp stop_process(pid) do
    _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end

  defp run_held_guard(context, args, env) do
    proxy = Path.join(context.state_path, "hold-proxy-broker.py")
    holds = Path.join(context.state_path, "broker-holds")
    File.mkdir_p!(context.state_path)

    File.write!(proxy, """
    import os, subprocess, sys
    result = subprocess.run([sys.executable, os.environ["HOLD_PROXY_REAL_BROKER"], *sys.argv[1:]], capture_output=True, text=True)
    sys.stderr.write(result.stderr)
    if sys.argv[1] == "acquire" and result.stdout.startswith("wait"):
        with open(os.environ["HOLD_PROXY_HOLDS"], "a") as holds:
            holds.write(result.stdout)
        print("wait 0")
        sys.exit(0)
    sys.stdout.write(result.stdout)
    sys.exit(result.returncode)
    """)

    File.chmod!(proxy, 0o755)

    proxy_env =
      Keyword.merge(env,
        AIUR_GITHUB_BUDGET_BROKER: proxy,
        HOLD_PROXY_REAL_BROKER: Keyword.fetch!(env, :AIUR_GITHUB_BUDGET_BROKER),
        HOLD_PROXY_HOLDS: holds
      )

    assert {output, 75} = run_guard(context, args, proxy_env)
    assert output =~ "invalid or unusable wait response"
    String.trim(File.read!(holds))
  end
end
