defmodule Aiur.AgentGitHubGuard.DeadlineSignalTest do
  use Aiur.AgentGitHubGuardCase, async: true

  test "TERM never waits on the child while its signal handler is active", context do
    broker = Path.join(context.workspace, "term-broker.py")
    python_bin = Path.join(context.workspace, "term-python-bin")
    shim = Path.join(python_bin, "python3")
    ready_file = Path.join(context.workspace, "term-ready")
    nested_wait_file = Path.join(context.workspace, "term-nested-wait")
    python_calls_file = Path.join(context.workspace, "term-python-calls")
    supervisor_pid_file = Path.join(context.workspace, "term-supervisor.pid")
    broker_pid_file = Path.join(context.workspace, "term-broker.pid")
    child_pid_file = Path.join(context.workspace, "term-child.pid")
    child_start_file = Path.join(context.workspace, "term-child.start")
    File.mkdir_p!(python_bin)
    real_python = System.find_executable("python3") || flunk("python3 is required")

    File.write!(shim, """
    #!#{real_python}
    import os, sys
    arguments = sys.argv[1:]
    with open(os.environ["AIUR_GH_TERM_PYTHON_CALLS_FILE"], "a") as calls:
        calls.write(repr(arguments[:2]) + chr(10))
    if len(arguments) >= 3 and arguments[:2] == ["-I", "-c"]:
        instrumentation = r'''\
    import os as _os, signal as _signal, subprocess as _subprocess, time as _time
    _in_term_handler = False
    _real_signal = _signal.signal
    def _tracked_signal(signum, handler):
        if signum == _signal.SIGTERM and callable(handler):
            def _wrapped(*args):
                global _in_term_handler
                _in_term_handler = True
                try:
                    return handler(*args)
                finally:
                    _in_term_handler = False
            return _real_signal(signum, _wrapped)
        return _real_signal(signum, handler)
    _signal.signal = _tracked_signal
    _real_wait = _subprocess.Popen.wait
    def _tracked_wait(self, *args, **kwargs):
        if _in_term_handler:
            with open(_os.environ["AIUR_GH_TERM_NESTED_WAIT_FILE"], "w") as marker:
                marker.write("wait called inside handler")
        return _real_wait(self, *args, **kwargs)
    _subprocess.Popen.wait = _tracked_wait
    _real_waitpid = _os.waitpid
    _term_sent = False
    def _waitpid_with_term(pid, options):
        global _term_sent
        ready = _os.environ.get("AIUR_GH_TERM_READY_FILE")
        if not _term_sent and ready and _os.path.exists(ready):
            _term_sent = True
            _os.kill(_os.getpid(), _signal.SIGTERM)
            _time.sleep(0.02)
        return _real_waitpid(pid, options)
    _os.waitpid = _waitpid_with_term
    with open(_os.environ["AIUR_GH_TERM_SUPERVISOR_PID_FILE"], "w") as output:
        output.write(str(_os.getpid()))
    '''
        arguments[2] = instrumentation + chr(10) + arguments[2]
    os.execv(os.environ["AIUR_GH_TERM_REAL_PYTHON"], [os.environ["AIUR_GH_TERM_REAL_PYTHON"], *arguments])
    """)

    File.chmod!(shim, 0o700)

    File.write!(broker, """
    import os, signal, subprocess, time
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    child = subprocess.Popen(["/bin/sh", "-c", "trap '' TERM; exec sleep 30"])
    for env_name, value in [("AIUR_GH_TERM_BROKER_PID_FILE", os.getpid()), ("AIUR_GH_TERM_CHILD_PID_FILE", child.pid)]:
        with open(os.environ[env_name], "w") as output:
            output.write(str(value))
    with open(f"/proc/{child.pid}/stat", encoding="ascii") as stat_file:
        child_start_time = stat_file.read().rsplit(")", 1)[1].split()[19]
    with open(os.environ["AIUR_GH_TERM_CHILD_START_FILE"], "w") as output:
        output.write(child_start_time)
    with open(os.environ["AIUR_GH_TERM_READY_FILE"], "w") as output:
        output.write("ready")
    time.sleep(30)
    """)

    File.chmod!(broker, 0o700)

    env =
      guard_env(context) ++
        Enum.map(
          [
            AIUR_GITHUB_BUDGET_ENABLED: "1",
            AIUR_GITHUB_BUDGET_ROOT: Path.join(context.state_path, "term-budget"),
            AIUR_GITHUB_BUDGET_KEY: String.duplicate("f", 64),
            AIUR_GITHUB_BUDGET_BROKER: broker,
            AIUR_GH_TERM_READY_FILE: ready_file,
            AIUR_GH_TERM_NESTED_WAIT_FILE: nested_wait_file,
            AIUR_GH_TERM_PYTHON_CALLS_FILE: python_calls_file,
            AIUR_GH_TERM_SUPERVISOR_PID_FILE: supervisor_pid_file,
            AIUR_GH_TERM_BROKER_PID_FILE: broker_pid_file,
            AIUR_GH_TERM_CHILD_PID_FILE: child_pid_file,
            AIUR_GH_TERM_CHILD_START_FILE: child_start_file,
            AIUR_GH_TERM_REAL_PYTHON: real_python,
            PATH: python_bin <> ":" <> System.get_env("PATH", ""),
            AIUR_GH_CALL_TIMEOUT_SECONDS: "30"
          ],
          fn {name, value} -> {Atom.to_string(name), value} end
        )

    assert {resolved_python, 0} = System.cmd("sh", ["-c", "command -v python3"], env: env)
    assert String.trim(resolved_python) == shim

    port =
      Port.open({:spawn_executable, context.wrapper}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: Enum.map(["api", "rate_limit"], &String.to_charlist/1),
        env: Enum.map(env, fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)
      ])

    on_exit(fn ->
      Enum.each([supervisor_pid_file, broker_pid_file, child_pid_file], fn path ->
        if File.exists?(path) do
          pid = path |> File.read!() |> String.to_integer()
          _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        end
      end)

      if Port.info(port), do: Port.close(port)
    end)

    wait_for_setup = fn wait_for_setup, attempts ->
      if File.exists?(ready_file) and File.exists?(supervisor_pid_file) do
        :ok
      else
        receive do
          {^port, {:data, output}} -> flunk("guard setup failed: #{output}")
          {^port, {:exit_status, status}} -> flunk("guard exited during setup with #{status}")
        after
          10 ->
            if attempts == 0 do
              calls = File.read(python_calls_file) || :no_calls
              flunk("guard setup files: #{inspect(File.ls!(context.workspace))}; python: #{inspect(calls)}")
            else
              wait_for_setup.(wait_for_setup, attempts - 1)
            end
        end
      end
    end

    wait_for_setup.(wait_for_setup, 500)

    supervisor_pid = supervisor_pid_file |> File.read!() |> String.to_integer()
    broker_pid = broker_pid_file |> File.read!() |> String.to_integer()
    child_pid = child_pid_file |> File.read!() |> String.to_integer()
    child_start_time = File.read!(child_start_file) |> String.trim()

    assert_receive {^port, {:exit_status, 143}}, 3_000
    refute File.exists?(nested_wait_file), "the TERM handler synchronously waited on its child"
    wait_until(fn -> process_gone?(supervisor_pid) and process_gone?(broker_pid) end)
    wait_until(fn -> process_gone?(child_pid, child_start_time) end)
    assert process_gone?(child_pid, child_start_time)
  end

  defp process_gone?(pid), do: process_identity(pid) == :gone or match?({:ok, "Z", _}, process_identity(pid))

  defp process_gone?(pid, original_start_time) do
    case process_identity(pid) do
      {:ok, "Z", _start_time} -> true
      {:ok, _state, start_time} -> start_time != original_start_time
      :gone -> true
    end
  end

  defp process_identity(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        [_command, fields] = String.split(stat, ")", parts: 2)
        [state | rest] = String.split(fields)
        {:ok, state, Enum.at(rest, 18)}

      {:error, :enoent} ->
        :gone

      {:error, _reason} ->
        :gone
    end
  end
end
