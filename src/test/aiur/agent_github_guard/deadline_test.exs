defmodule Aiur.AgentGitHubGuard.DeadlineTest do
  use Aiur.AgentGitHubGuardCase, async: true

  test "a broker that never answers is terminated with the governed call", context do
    broker = Path.join(context.workspace, "never-answers.py")
    pid_file = Path.join(context.workspace, "broker.pid")
    broker_pgid_file = Path.join(context.workspace, "broker.pgid")
    supervisor_pgid_file = Path.join(context.workspace, "supervisor.pgid")
    child_pid_file = Path.join(context.workspace, "broker-child.pid")
    child_pgid_file = Path.join(context.workspace, "broker-child.pgid")

    File.write!(broker, """
    import os, subprocess, time
    child = subprocess.Popen(["/bin/sh", "-c", "trap '' TERM; exec sleep 5"])
    with open(os.environ["AIUR_GH_NEVER_ANSWERS_CHILD_PID_FILE"], "w", encoding="utf-8") as pid_file:
        pid_file.write(str(child.pid))
    with open(os.environ["AIUR_GH_NEVER_ANSWERS_CHILD_PGID_FILE"], "w", encoding="utf-8") as pgid_file:
        pgid_file.write(str(os.getpgid(child.pid)))
    with open(os.environ["AIUR_GH_NEVER_ANSWERS_PID_FILE"], "w", encoding="utf-8") as pid_file:
        pid_file.write(str(os.getpid()))
    with open(os.environ["AIUR_GH_NEVER_ANSWERS_BROKER_PGID_FILE"], "w", encoding="utf-8") as pgid_file:
        pgid_file.write(str(os.getpgrp()))
    supervisor_pid = os.getppid()
    supervisor_pgid = None
    while supervisor_pid > 1:
        with open(f"/proc/{supervisor_pid}/stat", encoding="ascii") as parent_stat:
            fields = parent_stat.read().rsplit(")", 1)[1].split()
        with open(f"/proc/{supervisor_pid}/cmdline", "rb") as parent_cmdline:
            command_line = parent_cmdline.read()
        if b"@aiur-deadline-body@" in command_line:
            supervisor_pgid = int(fields[2])
            break
        supervisor_pid = int(fields[1])
    if supervisor_pgid is None:
        raise RuntimeError("deadline supervisor was not found in broker ancestors")
    with open(os.environ["AIUR_GH_NEVER_ANSWERS_SUPERVISOR_PGID_FILE"], "w", encoding="utf-8") as pgid_file:
        pgid_file.write(str(supervisor_pgid))
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
               AIUR_GH_NEVER_ANSWERS_CHILD_PGID_FILE: child_pgid_file,
               AIUR_GH_NEVER_ANSWERS_PID_FILE: pid_file,
               AIUR_GH_NEVER_ANSWERS_BROKER_PGID_FILE: broker_pgid_file,
               AIUR_GH_NEVER_ANSWERS_SUPERVISOR_PGID_FILE: supervisor_pgid_file
             )

    assert output =~ "governed gh call exceeded 1s deadline; terminated process group"
    assert System.monotonic_time(:millisecond) - started_at < 4_000

    broker_pid = pid_file |> File.read!() |> String.to_integer()
    assert process_gone?(broker_pid)
    child_pid = child_pid_file |> File.read!() |> String.to_integer()
    broker_pgid = broker_pgid_file |> File.read!() |> String.to_integer()
    supervisor_pgid = supervisor_pgid_file |> File.read!() |> String.to_integer()
    child_pgid = child_pgid_file |> File.read!() |> String.to_integer()
    assert broker_pgid == supervisor_pgid
    assert child_pgid == broker_pgid
    wait_until(fn -> process_gone?(child_pid) end)
    assert process_gone?(child_pid)
  end

  test "a caller group kill does not leave a broker descendant running", context do
    broker = Path.join(context.workspace, "caller-kill-broker.py")
    broker_pid_file = Path.join(context.workspace, "caller-kill-broker.pid")
    broker_pgid_file = Path.join(context.workspace, "caller-kill-broker.pgid")
    child_pid_file = Path.join(context.workspace, "caller-kill-child.pid")
    child_pgid_file = Path.join(context.workspace, "caller-kill-child.pgid")
    supervisor_pgid_file = Path.join(context.workspace, "caller-kill-supervisor.pgid")

    File.write!(broker, """
    import os, subprocess, time
    with open(os.environ["AIUR_GH_CALLER_KILL_BROKER_PID_FILE"], "w", encoding="ascii") as output:
        output.write(str(os.getpid()))
    with open(os.environ["AIUR_GH_CALLER_KILL_BROKER_PGID_FILE"], "w", encoding="ascii") as output:
        output.write(str(os.getpgrp()))
    child = subprocess.Popen(["/bin/sh", "-c", "trap '' TERM; exec sleep 30"])
    with open(os.environ["AIUR_GH_CALLER_KILL_CHILD_PID_FILE"], "w", encoding="ascii") as output:
        output.write(str(child.pid))
    with open(os.environ["AIUR_GH_CALLER_KILL_CHILD_PGID_FILE"], "w", encoding="ascii") as output:
        output.write(str(os.getpgid(child.pid)))
    pid = os.getppid()
    while pid > 1:
        with open(f"/proc/{pid}/stat", encoding="ascii") as stat_file:
            fields = stat_file.read().rsplit(")", 1)[1].split()
        with open(f"/proc/{pid}/cmdline", "rb") as cmdline_file:
            command_line = cmdline_file.read()
        if b"@aiur-deadline-body@" in command_line:
            with open(os.environ["AIUR_GH_CALLER_KILL_PGID_FILE"], "w", encoding="ascii") as output:
                output.write(fields[2])
            break
        pid = int(fields[1])
    else:
        raise RuntimeError("deadline supervisor was not found")
    time.sleep(30)
    """)

    File.chmod!(broker, 0o700)

    env =
      guard_env(context) ++
        Enum.map(
          [
            AIUR_GITHUB_BUDGET_ENABLED: "1",
            AIUR_GITHUB_BUDGET_ROOT: Path.join(context.state_path, "caller-kill-budget"),
            AIUR_GITHUB_BUDGET_KEY: String.duplicate("e", 64),
            AIUR_GITHUB_BUDGET_BROKER: broker,
            AIUR_GH_CALLER_KILL_BROKER_PID_FILE: broker_pid_file,
            AIUR_GH_CALLER_KILL_BROKER_PGID_FILE: broker_pgid_file,
            AIUR_GH_CALLER_KILL_CHILD_PID_FILE: child_pid_file,
            AIUR_GH_CALLER_KILL_CHILD_PGID_FILE: child_pgid_file,
            AIUR_GH_CALLER_KILL_PGID_FILE: supervisor_pgid_file,
            AIUR_GH_CALL_TIMEOUT_SECONDS: "30"
          ],
          fn {name, value} -> {Atom.to_string(name), value} end
        )

    port = open_caller_group_port(context, env)

    on_exit(fn ->
      Enum.each([broker_pid_file, child_pid_file], fn path ->
        if File.exists?(path) do
          pid = path |> File.read!() |> String.to_integer()
          _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        end
      end)

      if Port.info(port), do: Port.close(port)
    end)

    wait_for_port_files(port, [child_pid_file, supervisor_pgid_file])
    child_pid = child_pid_file |> File.read!() |> String.to_integer()
    pgid = supervisor_pgid_file |> File.read!() |> String.trim()
    assert File.read!(broker_pgid_file) == pgid
    assert File.read!(child_pgid_file) == pgid
    child_start_time = process_start_time!(child_pid)

    assert {"", 0} = System.cmd("kill", ["-KILL", "-#{pgid}"])
    assert_receive_port_exit(port, pgid, 2_000)
    wait_until(fn -> process_gone?(child_pid, child_start_time) end)
    assert process_gone?(child_pid, child_start_time)
  end

  test "repeated broker wait responses fail at the admission bound before gh runs", context do
    broker = Path.join(context.workspace, "always-waits.py")
    File.write!(broker, "print('wait 1000')\n")
    File.chmod!(broker, 0o700)
    started_at = System.monotonic_time(:millisecond)

    assert {output, 75} =
             run_guard(context, ["api", "rate_limit"],
               AIUR_GITHUB_BUDGET_ROOT: Path.join(context.state_path, "busy-budget"),
               AIUR_GITHUB_BUDGET_KEY: String.duplicate("b", 64),
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GITHUB_ADMISSION_WAIT_MS: "1000"
             )

    assert output =~ "GitHub budget broker busy; admission wait exceeded 1000ms"
    assert System.monotonic_time(:millisecond) - started_at < 4_000
    refute File.exists?(context.calls)
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

  test "caller-group TERM kills an orphaned TERM-ignoring broker descendant", context do
    broker = Path.join(context.workspace, "group-term-broker.py")
    broker_pid_file = Path.join(context.workspace, "group-term-broker.pid")
    child_pid_file = Path.join(context.workspace, "group-term-child.pid")
    child_start_file = Path.join(context.workspace, "group-term-child.start")
    supervisor_pid_file = Path.join(context.workspace, "group-term-supervisor.pid")
    pgid_file = Path.join(context.workspace, "group-term.pgid")
    ready_file = Path.join(context.workspace, "group-term.ready")

    File.write!(broker, """
    import os, subprocess, time
    child = subprocess.Popen(["/bin/sh", "-c", "trap '' TERM; exec sleep 30"])
    values = {
        os.environ["AIUR_GH_GROUP_TERM_BROKER_PID_FILE"]: os.getpid(),
        os.environ["AIUR_GH_GROUP_TERM_CHILD_PID_FILE"]: child.pid,
        os.environ["AIUR_GH_GROUP_TERM_PGID_FILE"]: os.getpgrp(),
    }
    for path, value in values.items():
        with open(path, "w", encoding="ascii") as output:
            output.write(str(value))
    with open(f"/proc/{child.pid}/stat", encoding="ascii") as stat_file:
        child_start = stat_file.read().rsplit(")", 1)[1].split()[19]
    with open(os.environ["AIUR_GH_GROUP_TERM_CHILD_START_FILE"], "w", encoding="ascii") as output:
        output.write(child_start)
    pid = os.getppid()
    while pid > 1:
        with open(f"/proc/{pid}/stat", encoding="ascii") as stat_file:
            fields = stat_file.read().rsplit(")", 1)[1].split()
        with open(f"/proc/{pid}/cmdline", "rb") as cmdline_file:
            command_line = cmdline_file.read()
        if b"@aiur-deadline-body@" in command_line:
            with open(os.environ["AIUR_GH_GROUP_TERM_SUPERVISOR_PID_FILE"], "w", encoding="ascii") as output:
                output.write(str(pid))
            break
        pid = int(fields[1])
    else:
        raise RuntimeError("deadline supervisor was not found")
    with open(os.environ["AIUR_GH_GROUP_TERM_READY_FILE"], "w", encoding="ascii") as output:
        output.write("ready")
    time.sleep(30)
    """)

    File.chmod!(broker, 0o700)

    env =
      guard_env(context) ++
        Enum.map(
          [
            AIUR_GITHUB_BUDGET_ENABLED: "1",
            AIUR_GITHUB_BUDGET_ROOT: Path.join(context.state_path, "group-term-budget"),
            AIUR_GITHUB_BUDGET_KEY: String.duplicate("g", 64),
            AIUR_GITHUB_BUDGET_BROKER: broker,
            AIUR_GH_GROUP_TERM_BROKER_PID_FILE: broker_pid_file,
            AIUR_GH_GROUP_TERM_CHILD_PID_FILE: child_pid_file,
            AIUR_GH_GROUP_TERM_CHILD_START_FILE: child_start_file,
            AIUR_GH_GROUP_TERM_SUPERVISOR_PID_FILE: supervisor_pid_file,
            AIUR_GH_GROUP_TERM_PGID_FILE: pgid_file,
            AIUR_GH_GROUP_TERM_READY_FILE: ready_file,
            AIUR_GH_CALL_TIMEOUT_SECONDS: "30"
          ],
          fn {name, value} -> {Atom.to_string(name), value} end
        )

    port = open_caller_group_port(context, env)

    on_exit(fn ->
      Enum.each([supervisor_pid_file, broker_pid_file, child_pid_file], fn path ->
        if File.exists?(path) do
          pid = path |> File.read!() |> String.to_integer()
          _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        end
      end)

      if Port.info(port), do: Port.close(port)
    end)

    wait_for_port_files(port, [ready_file])
    broker_pid = broker_pid_file |> File.read!() |> String.to_integer()
    child_pid = child_pid_file |> File.read!() |> String.to_integer()
    child_start = File.read!(child_start_file) |> String.trim()
    supervisor_pid = supervisor_pid_file |> File.read!() |> String.trim()
    pgid = pgid_file |> File.read!() |> String.trim()

    assert {"", 0} = System.cmd("kill", ["-TERM", "-#{pgid}"])
    assert_receive_port_exit(port, pgid, 3_000)
    wait_until(fn -> process_gone?(String.to_integer(supervisor_pid)) end)
    wait_until(fn -> process_gone?(broker_pid) end)
    wait_until(fn -> process_gone?(child_pid, child_start) end)
    assert process_gone?(child_pid, child_start)
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

  test "the supervisor keeps its body off TMPDIR", context do
    tmpdir = Path.join(context.workspace, "guard-tmp")
    File.mkdir_p!(tmpdir)
    tmpdir_snapshot = Path.join(context.workspace, "tmpdir-snapshot")
    fake_gh = Path.join(context.workspace, "fake-gh")
    File.write!(fake_gh, "#!/bin/sh\nls -A \"$TMPDIR\" > \"$GH_TMPDIR_SNAPSHOT\"\nprintf 'ok\\n'\n")
    File.chmod!(fake_gh, 0o700)

    assert {"ok\n", 0} =
             run_guard(context, ["auth", "token"],
               TMPDIR: tmpdir,
               GH_TMPDIR_SNAPSHOT: tmpdir_snapshot,
               AIUR_REAL_GH: fake_gh,
               AIUR_GITHUB_BUDGET_ENABLED: "0",
               AIUR_GH_CALL_TIMEOUT_SECONDS: "2"
             )

    assert File.read!(tmpdir_snapshot) == ""
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
    case process_identity(pid) do
      {:ok, "Z", _start_time} -> true
      {:ok, _state, _start_time} -> false
      :gone -> true
    end
  end

  defp process_gone?(pid, original_start_time) do
    case process_identity(pid) do
      {:ok, "Z", _start_time} -> true
      {:ok, _state, start_time} -> start_time != original_start_time
      :gone -> true
    end
  end

  defp open_caller_group_port(context, env) do
    launcher = Path.join(context.workspace, "caller-group-launcher.py")
    python = System.find_executable("python3") || flunk("python3 is required")

    # A setsid --wait wrapper may fork when the spawned port is a group leader,
    # leaving its waiter outside the group that the test signals.
    File.write!(launcher, """
    import os, sys
    parent = os.getppid()
    if os.getsid(0) == os.getsid(parent):
        if os.getpgrp() == os.getpid():
            os.setpgid(0, os.getpgid(parent))
        os.setsid()
    os.execv(sys.argv[1], sys.argv[1:])
    """)

    Port.open({:spawn_executable, python}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: Enum.map([launcher, context.wrapper, "api", "rate_limit"], &String.to_charlist/1),
      env: Enum.map(env, fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)
    ])
  end

  defp assert_receive_port_exit(port, pgid, timeout) do
    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      timeout ->
        {processes, _status} =
          System.cmd("ps", ["-eo", "pid,ppid,pgid,sid,stat,args"], stderr_to_stdout: true)

        survivors =
          processes
          |> String.split("\n")
          |> Enum.filter(&String.contains?(&1, " #{pgid} "))
          |> Enum.join("\n")

        flunk(
          "port #{inspect(Port.info(port, :os_pid))} did not exit after signaling process group #{pgid}; " <>
            "processes still in that group:\n#{survivors}\nall processes:\n#{processes}"
        )
    end
  end

  defp wait_for_port_files(port, paths, attempts \\ 500) do
    cond do
      Enum.all?(paths, &File.exists?/1) ->
        :ok

      attempts == 0 ->
        flunk("caller group launcher did not create #{inspect(paths)}")

      true ->
        receive do
          {^port, {:data, output}} -> flunk("caller group launcher failed: #{output}")
          {^port, {:exit_status, status}} -> flunk("caller group launcher exited before setup: #{status}")
        after
          10 -> wait_for_port_files(port, paths, attempts - 1)
        end
    end
  end

  defp process_start_time!(pid) do
    case process_identity(pid) do
      {:ok, _state, start_time} -> start_time
      :gone -> flunk("process #{pid} disappeared before its identity was recorded")
    end
  end

  defp process_identity(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        case String.split(stat, ")", parts: 2) do
          [_command, fields] ->
            [state | rest] = String.split(fields)
            {:ok, state, Enum.at(rest, 18)}

          _malformed ->
            :gone
        end

      {:error, :enoent} ->
        :gone

      {:error, _reason} ->
        :gone
    end
  end
end
