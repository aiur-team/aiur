defmodule Aiur.AgentGitHubGuard.CallerGroupTest do
  use Aiur.AgentGitHubGuardCase, async: true

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

  defp process_gone?(pid, original_start_time) do
    case process_identity(pid) do
      {:ok, "Z", _start_time} -> true
      {:ok, _state, start_time} -> start_time != original_start_time
      :gone -> true
    end
  end

  defp process_gone?(pid) do
    case process_identity(pid) do
      {:ok, "Z", _start_time} -> true
      {:ok, _state, _start_time} -> false
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
