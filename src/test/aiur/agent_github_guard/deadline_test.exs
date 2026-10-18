defmodule Aiur.AgentGitHubGuard.DeadlineTest do
  use Aiur.AgentGitHubGuardCase, async: true

  test "a broker that never answers is terminated with the governed call", context do
    broker = Path.join(context.workspace, "never-answers.py")
    pid_file = Path.join(context.workspace, "broker.pid")
    child_pid_file = Path.join(context.workspace, "broker-child.pid")

    File.write!(broker, """
    import os, subprocess, time
    child = subprocess.Popen(["/bin/sh", "-c", "trap '' TERM; exec sleep 5"])
    with open(os.environ["AIUR_GH_NEVER_ANSWERS_CHILD_PID_FILE"], "w", encoding="utf-8") as pid_file:
        pid_file.write(str(child.pid))
    with open(os.environ["AIUR_GH_NEVER_ANSWERS_PID_FILE"], "w", encoding="utf-8") as pid_file:
        pid_file.write(str(os.getpid()))
    time.sleep(5)
    """)

    File.chmod!(broker, 0o700)

    started_at = System.monotonic_time(:millisecond)

    assert {output, 124} =
             run_guard(context, ["api", "rate_limit"],
               AIUR_GH_CALL_TIMEOUT_SECONDS: "1",
               AIUR_GITHUB_BUDGET_ROOT: Path.join(context.state_path, "budget"),
               AIUR_GITHUB_BUDGET_KEY: String.duplicate("a", 64),
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GH_NEVER_ANSWERS_CHILD_PID_FILE: child_pid_file,
               AIUR_GH_NEVER_ANSWERS_PID_FILE: pid_file
             )

    assert output =~ "governed gh call exceeded 1s deadline; terminated process group"
    assert System.monotonic_time(:millisecond) - started_at < 4_000

    broker_pid = pid_file |> File.read!() |> String.to_integer()
    assert process_gone?(broker_pid)
    child_pid = child_pid_file |> File.read!() |> String.to_integer()
    assert process_gone?(child_pid)
  end

  test "the deadline also kills descendants that start their own session", context do
    broker = Path.join(context.workspace, "nested-never-answers.py")
    child_pid_file = Path.join(context.workspace, "nested-child.pid")

    File.write!(
      broker,
      "import os,subprocess,time\nchild=subprocess.Popen(['sleep','10'],start_new_session=True)\nopen(os.environ['AIUR_GH_NESTED_CHILD_PID_FILE'],'w').write(str(child.pid))\ntime.sleep(10)\n"
    )

    File.chmod!(broker, 0o700)

    assert {output, 124} =
             run_guard(context, ["api", "rate_limit"],
               AIUR_GH_CALL_TIMEOUT_SECONDS: "2",
               AIUR_GITHUB_BUDGET_ROOT: Path.join(context.state_path, "nested-budget"),
               AIUR_GITHUB_BUDGET_KEY: String.duplicate("d", 64),
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GH_NESTED_CHILD_PID_FILE: child_pid_file
             )

    assert output =~ "terminated process group"
    assert process_gone?(child_pid_file |> File.read!() |> String.to_integer())
  end

  test "the supervisor preserves wrapper argv0 and caller stdin", context do
    stdin_file = Path.join(context.workspace, "stdin")
    File.write!(stdin_file, "")
    fake_gh = Path.join(context.workspace, "fake-gh")
    File.write!(fake_gh, "#!/bin/sh\ncat > \"$GH_STDIN_FILE\"\nprintf 'ok\\n'\n")
    File.chmod!(fake_gh, 0o700)

    assert {"ok\n", 0} =
             run_guard_with_stdin(
               context,
               ["auth", "status"],
               "caller graphql body",
               AIUR_REAL_GH: fake_gh,
               GH_STDIN_FILE: stdin_file,
               AIUR_GITHUB_BUDGET_ENABLED: "0"
             )

    assert File.read!(stdin_file) == "caller graphql body"
  end

  # #5101: the supervisor holds the injected credential, so caller Python
  # environment (PYTHONPATH, user site) must not run code inside it.
  test "a sitecustomize on the caller's PYTHONPATH does not run in the supervisor", context do
    planted = Path.join(context.workspace, "planted-python")
    marker = Path.join(context.workspace, "sitecustomize-ran")
    File.mkdir_p!(planted)
    File.write!(Path.join(planted, "sitecustomize.py"), "open(#{inspect(marker)}, 'w').close()\n")
    fake_gh = Path.join(context.workspace, "fake-gh")
    File.write!(fake_gh, "#!/bin/sh\nprintf 'ok\\n'\n")
    File.chmod!(fake_gh, 0o700)

    assert {"ok\n", 0} =
             run_guard(context, ["auth", "status"],
               AIUR_REAL_GH: fake_gh,
               PYTHONPATH: planted,
               AIUR_GITHUB_BUDGET_ENABLED: "0"
             )

    refute File.exists?(marker)
  end

  test "merge gate still identifies the agent from the installed wrapper path", context do
    env = Enum.reject(guard_env(context), fn {name, _value} -> name == "AIUR_AGENT_WORKSPACE" end) ++ [{"AIUR_AGENT_WORKSPACE", ""}]

    assert {output, 77} =
             System.cmd(context.wrapper, ["pr", "merge", "1670", "--squash"], env: env, stderr_to_stdout: true)

    assert output =~ "agents cannot approve or merge pull requests"
    refute File.exists?(context.calls)
  end

  test "a timed-out held lease stays counted and cleans stamped body files", context do
    budget_root = Path.join(context.state_path, "budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    body = Path.join(context.workspace, "comment.md")
    slow_gh = Path.join(context.workspace, "slow-gh")
    tmpdir = Path.join(context.workspace, "marked-body-tmp")
    File.mkdir_p!(tmpdir)
    File.write!(body, "comment")
    File.write!(slow_gh, "#!/bin/sh\nprintf 'started' > \"$GH_STARTED_FILE\"\nsleep 10\n")
    File.chmod!(slow_gh, 0o700)
    marker = "agent marker"

    assert {output, 124} =
             run_guard(context, ["issue", "comment", "1670", "--body-file", body],
               TMPDIR: tmpdir,
               GH_STARTED_FILE: Path.join(context.workspace, "gh-started"),
               AIUR_GH_CALL_TIMEOUT_SECONDS: "5",
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_KEY: String.duplicate("c", 64),
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GITHUB_LEASE_TTL_MS: "2000",
               AIUR_AGENT_COMMENT_MARKER: marker,
               AIUR_REAL_GH: slow_gh
             )

    assert output =~ "terminated process group"
    assert File.read!(Path.join(context.workspace, "gh-started")) == "started"
    assert Path.wildcard(Path.join(tmpdir, "aiur-marked-body.*")) == []

    assert {snapshot, 0} =
             System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", String.duplicate("c", 64)])

    assert %{"admissions" => [_ | _], "inflight" => %{} = leases} = Jason.decode!(snapshot)
    assert map_size(leases) == 1

    wait_until(fn ->
      {expired_snapshot, 0} =
        System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", String.duplicate("c", 64)])

      %{"admissions" => [_ | _], "inflight" => inflight} = Jason.decode!(expired_snapshot)
      map_size(inflight) == 0
    end)
  end

  defp process_gone?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        stat |> String.split() |> Enum.at(2) == "Z"

      {:error, :enoent} ->
        true
    end
  end
end
