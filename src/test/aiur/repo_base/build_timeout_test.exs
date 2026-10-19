defmodule Aiur.RepoBase.BuildTimeoutTest do
  use Aiur.RepoBaseCase

  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.RepoBase.BuildProcess
  alias Aiur.RepoBase.Clone

  defmodule TestServer do
    @spec child_spec(keyword()) :: Supervisor.child_spec()
    def child_spec(opts) do
      id = Keyword.get(opts, :child_id, __MODULE__)
      shutdown = Keyword.get(opts, :child_shutdown, 5_000)
      opts = Keyword.drop(opts, [:child_id, :child_shutdown])

      %{id: id, start: {__MODULE__, :start_link, [opts]}, restart: :temporary, shutdown: shutdown, type: :worker}
    end

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts), do: GenServer.start_link(Aiur.RepoBase, opts)
  end

  setup do
    tmp = Aiur.TestSupport.tmp_root!("rb_timeout_cfg")
    File.mkdir_p!(tmp)
    cfg = Path.join(tmp, "config")
    File.write!(cfg, "tracker:\n  kind: memory\n")
    previous_path = Application.get_env(:aiur, :workflow_file_path)
    Aiur.Workflow.set_workflow_file_path(cfg)
    server = start_supervised!({TestServer, [child_id: :initial_server]})

    on_exit(fn ->
      case previous_path do
        nil -> Aiur.Workflow.clear_workflow_file_path()
        path -> Aiur.Workflow.set_workflow_file_path(path)
      end

      Aiur.TestCleanup.rm_rf!(tmp)
    end)

    {:ok, server: server, cfg: cfg}
  end

  test "a real progressing build remains alive across idle watchdog re-arms", %{server: pid, cfg: cfg, tmp: tmp, origin: origin} do
    pidfile = Path.join(tmp, "progressing-build.pid")
    pid = start_real_build(pid, cfg, tmp, origin, "echo $$ > #{pidfile}; sleep 600", dispatch_hold_timeout_ms: 40, build_hold_timeout_ms: 10_000)
    Phoenix.PubSub.subscribe(Aiur.PubSub, "prewarm:phase")

    assert :building = GenServer.call(pid, :refresh_for_dispatch)
    build_os_pid = await_file(pidfile, 5_000) |> String.trim() |> String.to_integer()
    state = wait_for_build_os_pid(pid, build_os_pid)
    os_pid = state.build.os_pid
    timer = state.build.timer

    refute_receive {:prewarm_phase, {:error, {:repo_base_build_hold_timeout, _}}}, 2_000
    assert %{phase: :building, build: %{os_pid: ^os_pid, timer: ^timer}} = :sys.get_state(pid)
    assert Aiur.ProcessTree.process_alive?(os_pid)
  end

  test "the production deadline kills the OS process tree, releases dispatch, and suppresses poll retries", %{
    server: pid,
    cfg: cfg,
    tmp: tmp,
    origin: origin
  } do
    pidfile = Path.join(tmp, "stalled-build-child.pid")
    command = "trap 'wait \"$child\"' TERM; sleep 600 & child=$!; echo $child > #{pidfile}; wait \"$child\""
    pid = start_real_build(pid, cfg, tmp, origin, command, dispatch_hold_timeout_ms: 30, build_hold_timeout_ms: 10_000)
    Phoenix.PubSub.subscribe(Aiur.PubSub, "prewarm:phase")

    assert :building = GenServer.call(pid, :refresh_for_dispatch)
    _initial_state = wait_for_build_process(pid)
    child_pid = await_file(pidfile, 5_000) |> String.trim() |> String.to_integer()
    state = :sys.get_state(pid)
    Agent.update(Process.get({__MODULE__, :process_tracker}), &Map.merge(&1, state.build.os_processes))
    assert Aiur.ProcessTree.process_alive?(child_pid)

    assert_receive {:prewarm_phase, {:error, {:repo_base_build_hold_timeout, 10_000}}}, 12_000

    assert Task.async(fn -> GenServer.call(pid, :status) end) |> Task.await(1_000) |> elem(0) ==
             {:error, {:repo_base_build_hold_timeout, 10_000}}

    # Allow the bounded process-tree cleanup to finish under CI load.
    wait_until(fn -> not Process.alive?(state.build.pid) and not Aiur.ProcessTree.process_alive?(child_pid) end, 20_000)

    refute Process.alive?(state.build.pid)
    refute Aiur.ProcessTree.process_alive?(child_pid)

    assert %{phase: {:error, {:repo_base_build_hold_timeout, 10_000}}, build: nil, dispatch_watchdog: nil} =
             :sys.get_state(pid)

    send(pid, :poll)
    assert %{phase: {:error, {:repo_base_build_hold_timeout, 10_000}}, build: nil} = :sys.get_state(pid)
    assert DispatchPolicy.prewarm_gate(true, GenServer.call(pid, :refresh_for_dispatch)) == :dispatch
  end

  test "the production deadline covers a stalled clone before build shell startup", %{server: pid, cfg: cfg, tmp: tmp, origin: origin} do
    git_bin = Path.join(tmp, "blocking-git")
    File.mkdir_p!(git_bin)
    pidfile = Path.join(tmp, "stalled-clone.pid")
    git_script = Path.join(git_bin, "git")

    File.write!(git_script, ~S"""
    #!/bin/sh
    if [ "$1" = clone ]; then
      echo $$ > "$AIUR_CLONE_PIDFILE"
      exec sleep 600
    fi
    exec /usr/bin/git "$@"
    """)

    File.chmod!(git_script, 0o755)

    pid =
      start_real_build(pid, cfg, tmp, origin, "true",
        dispatch_hold_timeout_ms: 25,
        build_hold_timeout_ms: 1_000,
        git_bin_dir: git_bin,
        clone_pidfile: pidfile,
        preclone: false
      )

    Phoenix.PubSub.subscribe(Aiur.PubSub, "prewarm:phase")

    assert :building = GenServer.call(pid, :refresh_for_dispatch)
    state = wait_for_build_process(pid)
    clone_pid = await_file(pidfile) |> String.trim() |> String.to_integer()
    assert Aiur.ProcessTree.process_alive?(clone_pid)

    assert_receive {:prewarm_phase, {:error, {:repo_base_build_hold_timeout, 1_000}}}, 3_000
    wait_until(fn -> not Aiur.ProcessTree.process_alive?(clone_pid) and not Process.alive?(state.build.pid) end, 20_000)
    refute Aiur.ProcessTree.process_alive?(clone_pid)
    assert %{phase: {:error, {:repo_base_build_hold_timeout, 1_000}}, build: nil} = :sys.get_state(pid)
  end

  test "stopping RepoBase terminates an active build process group", %{server: pid, cfg: cfg, tmp: tmp, origin: origin} do
    shell_pidfile = Path.join(tmp, "stopped-server-shell.pid")
    pidfile = Path.join(tmp, "stopped-server-child.pid")

    command =
      "echo $$ > #{shell_pidfile}; trap 'wait \"$child\"' TERM; sleep 600 & child=$!; echo $child > #{pidfile}; wait \"$child\""

    pid = start_real_build(pid, cfg, tmp, origin, command, dispatch_hold_timeout_ms: 30, build_hold_timeout_ms: 10_000)

    assert :building = GenServer.call(pid, :refresh_for_dispatch)
    shell_pid = await_file(shell_pidfile, 5_000) |> String.trim() |> String.to_integer()
    state = wait_for_build_os_pid(pid, shell_pid)
    child_pid = await_file(pidfile, 5_000) |> String.trim() |> String.to_integer()
    assert Aiur.ProcessTree.process_alive?(child_pid)
    assert Map.has_key?(state.build.os_processes, shell_pid)

    previous_cmd_fun = Application.get_env(:aiur, :process_exhaustion_cmd_fun)
    gate = spawn(fn -> reaper_gate_loop() end)
    Application.put_env(:aiur, :process_exhaustion_cmd_fun, reaper_gate(gate))

    on_exit(fn ->
      restore_env(:process_exhaustion_cmd_fun, previous_cmd_fun)
      send(gate, :stop)
    end)

    stopped_at = System.monotonic_time(:millisecond)
    :ok = stop_supervised!(:build_server)
    assert System.monotonic_time(:millisecond) - stopped_at >= 200
    refute Aiur.ProcessTree.process_alive?(child_pid)
    refute Process.alive?(state.build.pid)
  end

  test "a nil process-group record still reaps a detached descendant", %{tmp: tmp} do
    pidfile = Path.join(tmp, "detached-build-child.pid")
    command = "(sleep 600 >/dev/null 2>&1 & echo $! > #{pidfile}); exec sleep 600 >/dev/null 2>&1"
    port = open_shell_port(command)
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {:known, identity} = await_process_identity(os_pid)
    escaped_pid = await_file(pidfile) |> String.trim() |> String.to_integer()
    {:known, escaped_identity} = await_process_identity(escaped_pid)

    try do
      wait_until(fn -> escaped_pid not in Aiur.ProcessTree.process_tree(os_pid) end, 5_000)
      assert Aiur.ProcessTree.process_alive?(escaped_pid)

      :ok = BuildProcess.terminate_processes(%{os_pid => %{group_id: nil, identity: {:known, identity}}})

      wait_until(fn -> not Aiur.ProcessTree.process_alive?(os_pid) and not Aiur.ProcessTree.process_alive?(escaped_pid) end, 10_000)
      refute Aiur.ProcessTree.process_alive?(escaped_pid)
    after
      reap_process(os_pid, identity)
      reap_process(escaped_pid, escaped_identity)
      close_port(port)
    end
  end

  test "timeout cleanup finds a Port process before RepoBase registers its pid", %{tmp: tmp} do
    parent = self()
    pidfile = Path.join(tmp, "unregistered-build-child.pid")
    command = "(sleep 600 >/dev/null 2>&1 & echo $! > #{pidfile}); exec sleep 600 >/dev/null 2>&1"

    worker =
      spawn(fn ->
        port = open_shell_port(command)
        send(parent, {:build_port_open, self(), port})
        Process.sleep(:infinity)
      end)

    monitor = Process.monitor(worker)
    assert_receive {:build_port_open, ^worker, port}, 5_000
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {:known, identity} = await_process_identity(os_pid)
    escaped_pid = await_file(pidfile) |> String.trim() |> String.to_integer()
    {:known, escaped_identity} = await_process_identity(escaped_pid)

    try do
      wait_until(fn -> escaped_pid not in Aiur.ProcessTree.process_tree(os_pid) end, 5_000)
      assert Aiur.ProcessTree.process_alive?(escaped_pid)

      :ok = BuildProcess.kill_async(%{pid: worker, os_processes: %{}})
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 10_000
      wait_until(fn -> not Aiur.ProcessTree.process_alive?(os_pid) and not Aiur.ProcessTree.process_alive?(escaped_pid) end, 10_000)
      refute Aiur.ProcessTree.process_alive?(escaped_pid)
    after
      if Process.alive?(worker), do: Process.exit(worker, :kill)
      reap_process(os_pid, identity)
      reap_process(escaped_pid, escaped_identity)
      close_port(port)
    end
  end

  test "the configured timeout controls production builds", %{server: pid, cfg: cfg, tmp: tmp, origin: origin} do
    pid = start_real_build(pid, cfg, tmp, origin, "sleep 600", build_timeout_minutes: 2)
    assert :building = GenServer.call(pid, :refresh_for_dispatch)
    state = wait_for_build_process(pid)

    assert state.build.timeout_ms == 120_000
    assert state.build.timer
  end

  test "base build ports unset shell startup variables before starting the shell", %{tmp: tmp, origin: origin} do
    shell_dir = Path.join(tmp, "shell-bin")
    File.mkdir_p!(shell_dir)
    shell = Path.join(shell_dir, "sh")
    marker = Path.join(tmp, "startup-ran")
    startup = Path.join(tmp, "bash-env")
    base = Path.join(tmp, "startup-env-base")
    {_output, 0} = System.cmd("/usr/bin/git", ["clone", "--branch", "main", origin, base], stderr_to_stdout: true)
    File.write!(shell, "#!/bin/bash\nexit 0\n")
    File.chmod!(shell, 0o755)
    File.write!(startup, "touch #{marker}\n")
    previous_path = System.get_env("PATH")
    previous_bash_env = System.get_env("BASH_ENV")
    System.put_env("PATH", shell_dir <> ":" <> previous_path)
    System.put_env("BASH_ENV", startup)

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      restore_system_env("BASH_ENV", previous_bash_env)
    end)

    assert {:ok, ^base} = Clone.maybe_build(base, "true", true)
    refute File.exists?(marker)
  end

  test "pid-file polling waits for a complete integer", %{tmp: tmp} do
    pidfile = Path.join(tmp, "partial-pid-file")
    File.write!(pidfile, "")

    writer =
      Task.async(fn ->
        Process.sleep(25)
        File.write!(pidfile, "123\n")
      end)

    assert 123 = await_file(pidfile, 1_000) |> String.trim() |> String.to_integer()
    Task.await(writer)
  end

  def clone_url_for_test(origin), do: origin

  defp start_real_build(_pid, cfg, tmp, origin, command, opts) do
    root = Path.join(tmp, "repo-base-root")
    previous_root = Application.get_env(:aiur, :repo_base_root)
    previous_clone_url = Application.get_env(:aiur, :repo_base_clone_url)
    previous_path = System.get_env("PATH")
    previous_clone_pidfile = System.get_env("AIUR_CLONE_PIDFILE")
    real_git = System.get_env("AIUR_REAL_GIT") || "/usr/bin/git"
    {:ok, tracker} = Agent.start(fn -> %{} end)
    Process.put({__MODULE__, :process_tracker}, tracker)
    if clone_pidfile = Keyword.get(opts, :clone_pidfile), do: System.put_env("AIUR_CLONE_PIDFILE", clone_pidfile)
    Application.put_env(:aiur, :repo_base_root, root)
    Application.put_env(:aiur, :repo_base_clone_url, {__MODULE__, :clone_url_for_test, [origin]})
    if Keyword.get(opts, :preclone, true), do: preclone_base!(real_git, origin)
    git_bin_dir = Keyword.get(opts, :git_bin_dir)
    path_prefix = if git_bin_dir, do: git_bin_dir <> ":", else: ""
    System.put_env("PATH", path_prefix <> Path.dirname(real_git) <> ":" <> previous_path)

    :ok = stop_supervised!(:initial_server)

    File.write!(cfg, """
    tracker:
      kind: github
      base_branch: main
      github:
        repo: owner/project
    prewarm:
      enabled: true
      base_build: #{Jason.encode!(command)}
      poll_seconds: 0
      build_timeout_minutes: #{Keyword.get(opts, :build_timeout_minutes, 60)}
    """)

    :ok = Aiur.WorkflowStore.force_reload()

    server_opts =
      opts
      |> Keyword.drop([:git_bin_dir, :clone_pidfile, :preclone, :build_timeout_minutes, :child_shutdown])
      |> Keyword.put_new(:remote_head_fun, fn _repo_url -> Process.sleep(:infinity) end)

    server = start_supervised!({TestServer, [child_id: :build_server, child_shutdown: Keyword.get(opts, :child_shutdown, 5_000)] ++ server_opts})

    on_exit(fn ->
      BuildProcess.terminate_processes(Agent.get(tracker, & &1))

      case Process.alive?(server) && :sys.get_state(server) do
        %{build: %{pid: worker_pid} = build} ->
          BuildProcess.terminate_processes(build.os_processes)
          kill_worker(worker_pid)

        _ ->
          :ok
      end

      if Process.alive?(server), do: stop_supervised!(:build_server)
      restore_env(:repo_base_root, previous_root)
      restore_env(:repo_base_clone_url, previous_clone_url)
      System.put_env("PATH", previous_path)
      restore_system_env("AIUR_CLONE_PIDFILE", previous_clone_pidfile)
      Agent.stop(tracker)
    end)

    server
  end

  defp restore_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_env(key, value), do: Application.put_env(:aiur, key, value)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
  defp kill_worker(pid), do: if(Process.alive?(pid), do: Process.exit(pid, :kill))

  defp reaper_gate(gate) do
    fn command, args, opts ->
      if Path.basename(command) == "python3" and Enum.any?(args, &String.ends_with?(&1, "pidfd_reap.py")) do
        send(gate, {:reaper_waiting, self()})

        receive do
          :continue -> System.cmd(command, args, opts)
        after
          1_000 -> System.cmd(command, args, opts)
        end
      else
        System.cmd(command, args, opts)
      end
    end
  end

  defp reaper_gate_loop do
    receive do
      {:reaper_waiting, pid} ->
        Process.sleep(250)
        send(pid, :continue)
        reaper_gate_loop()

      :stop ->
        Process.sleep(1_100)
    end
  end

  defp preclone_base!(git, origin) do
    base = Aiur.RepoBase.base_path(origin)
    File.mkdir_p!(Path.dirname(base))
    {_output, 0} = System.cmd(git, ["clone", "--branch", "main", origin, base], stderr_to_stdout: true)
  end

  defp wait_for_build_process(pid, timeout_ms \\ 10_000) do
    wait_for_build_process_until(pid, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp wait_for_build_process_until(pid, deadline) do
    case :sys.get_state(pid) do
      %{build: %{os_pid: os_pid, timer: timer} = build} = state when is_integer(os_pid) and is_reference(timer) ->
        tracker = Process.get({__MODULE__, :process_tracker})

        if Map.has_key?(build.os_processes, os_pid) do
          Agent.update(tracker, &Map.merge(&1, build.os_processes))
          %{state | build: build}
        else
          retry_build_process_wait(pid, deadline)
        end

      _ ->
        retry_build_process_wait(pid, deadline)
    end
  end

  defp retry_build_process_wait(pid, deadline) do
    if System.monotonic_time(:millisecond) >= deadline, do: flunk("RepoBase did not start the build command")
    Process.sleep(10)
    wait_for_build_process_until(pid, deadline)
  end

  defp wait_for_build_os_pid(pid, expected_os_pid, timeout_ms \\ 10_000) do
    wait_for_build_os_pid_until(pid, expected_os_pid, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp wait_for_build_os_pid_until(pid, expected_os_pid, deadline) do
    case :sys.get_state(pid) do
      %{build: %{os_pid: ^expected_os_pid, timer: timer} = build} = state when is_reference(timer) ->
        tracker = Process.get({__MODULE__, :process_tracker})
        Agent.update(tracker, &Map.merge(&1, build.os_processes))
        %{state | build: build}

      _ ->
        if System.monotonic_time(:millisecond) >= deadline, do: flunk("RepoBase did not register the expected build process")
        Process.sleep(10)
        wait_for_build_os_pid_until(pid, expected_os_pid, deadline)
    end
  end

  defp await_file(path, timeout_ms \\ 10_000) do
    await_file_until(path, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp await_file_until(path, deadline) do
    case File.read(path) do
      {:ok, contents} ->
        if valid_pid_file?(contents) do
          contents
        else
          retry_file_read(path, deadline)
        end

      _ ->
        retry_file_read(path, deadline)
    end
  end

  defp valid_pid_file?(contents) do
    case Integer.parse(String.trim(contents)) do
      {_pid, ""} -> true
      _ -> false
    end
  end

  defp retry_file_read(path, deadline) do
    if System.monotonic_time(:millisecond) >= deadline, do: flunk("build command did not write a valid pid file")
    Process.sleep(10)
    await_file_until(path, deadline)
  end

  defp open_shell_port(command) do
    Port.open({:spawn_executable, ~c"/bin/sh"}, [:binary, :exit_status, args: [~c"-c", String.to_charlist(command)]])
  end

  defp await_process_identity(os_pid, timeout_ms \\ 5_000) do
    await_process_identity_until(os_pid, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp await_process_identity_until(os_pid, deadline) do
    case Aiur.ProcessTree.process_identity(os_pid) do
      {:ok, identity} ->
        {:known, identity}

      _ ->
        if System.monotonic_time(:millisecond) >= deadline, do: flunk("build command did not expose a process identity")
        Process.sleep(10)
        await_process_identity_until(os_pid, deadline)
    end
  end

  defp reap_process(os_pid, identity) do
    if Aiur.ProcessTree.process_alive?(os_pid), do: Aiur.ProcessTree.reap_process(os_pid, {:known, identity})
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp wait_until(predicate, timeout_ms) do
    wait_until(predicate, System.monotonic_time(:millisecond) + timeout_ms, :deadline)
  end

  defp wait_until(predicate, deadline, :deadline) do
    if predicate.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline, do: flunk("condition was not reached")
      Process.sleep(10)
      wait_until(predicate, deadline, :deadline)
    end
  end
end
