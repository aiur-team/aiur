defmodule Aiur.AppServer.RelayReaperTest do
  use Aiur.TestSupport

  alias Aiur.AppServer.{RelayPort, Transport}
  alias Aiur.Config.Paths
  alias Aiur.{ProcessReaper, ProcessTree}

  @moduletag :real_proc
  @engine Path.expand("../../../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)

  setup do
    root = Aiur.TestSupport.tmp_root!("relay-reaper")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    previous = Application.get_env(:aiur, :process_reaper_registrations)
    previous_pidfile = System.get_env("AIUR_AGENT_TMPFILE")
    Application.put_env(:aiur, :process_reaper_registrations, true)
    pidfile = Path.join(root, "relay-agents.pid")
    File.write!(pidfile, "")
    System.put_env("AIUR_AGENT_TMPFILE", pidfile)

    on_exit(fn ->
      Application.put_env(:aiur, :process_reaper_registrations, previous)
      if previous_pidfile, do: System.put_env("AIUR_AGENT_TMPFILE", previous_pidfile), else: System.delete_env("AIUR_AGENT_TMPFILE")
    end)

    %{pidfile: pidfile, workflow_root: root}
  end

  test "registry reaping stops a relay and its orphaned provider group but spares a mismatched command", context do
    {_relay, metadata, child} = start_relay(context.workflow_root)
    recycled = unrelated_process()
    ProcessReaper.register(:agent, {:os_pid, recycled}, comm: "agent_relay.py")

    assert Enum.any?(ProcessReaper.entries(), fn
             {{:os_pid, pid}, :agent, %{comm: "agent_relay.py"}} -> pid == metadata.relay_pid
             _ -> false
           end)

    assert File.read!(context.pidfile) =~ "pid #{metadata.relay_pid} agent_relay.py\n"
    assert ProcessReaper.reap([:agent]) == :ok
    assert_gone(metadata.relay_pid, metadata.provider_pid, child)
    assert live?(recycled)
  end

  test "launcher pidfile reaping stops relay and orphaned provider group and spares a mismatched command", context do
    {_relay, metadata, child} = start_relay(context.workflow_root)
    recycled = unrelated_process()
    ProcessReaper.register(:agent, {:os_pid, recycled}, comm: "agent_relay.py")

    assert {_, 0} = System.cmd("bash", ["-c", ~s(source "$1"; reap_aiur_agents "" "$2"), "relay-test", @engine, context.pidfile], stderr_to_stdout: true)
    assert_gone(metadata.relay_pid, metadata.provider_pid, child)
    assert live?(recycled)
  end

  test "BEAM-death watchdog uses the pidfile to stop relay and orphaned provider group", context do
    {_relay, metadata, child} = start_relay(context.workflow_root)
    recycled = unrelated_process()
    ProcessReaper.register(:agent, {:os_pid, recycled}, comm: "agent_relay.py")
    script = ~s(source "$1"; start_beam_death_watchdog "$RELAY_TEST_BEAM_PATTERN" "" "$2" 0.01 1)

    assert {watchdog, 0} =
             System.cmd("bash", ["-c", script, "relay-test", @engine, context.pidfile],
               env: [{"RELAY_TEST_BEAM_PATTERN", "absent-relay-test-beam-#{System.unique_integer([:positive])}"}],
               stderr_to_stdout: true
             )

    watchdog_pid = watchdog |> String.trim() |> String.to_integer()
    on_exit(fn -> ProcessTree.graceful_kill_tree(watchdog_pid) end)
    assert_gone(metadata.relay_pid, metadata.provider_pid, child)
    assert live?(recycled)
  end

  defp start_relay(root) do
    provider = Path.join(root, "provider.py")

    File.write!(provider, """
    import json, os, signal, time
    reader, writer = os.pipe()
    intermediate = os.fork()
    if intermediate == 0:
        os.close(reader)
        child = os.fork()
        if child == 0:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            os.write(writer, str(os.getpid()).encode())
            os.close(writer)
            for fd in (0, 1, 2):
                os.close(fd)
            time.sleep(600)
            os._exit(0)
        os._exit(0)
    os.close(writer)
    child = int(os.read(reader, 64))
    os.close(reader)
    os.waitpid(intermediate, 0)
    print(json.dumps({'child': child, 'pgid': os.getpgrp()}), flush=True)
    time.sleep(600)
    """)

    {:ok, runtime_root} = Paths.runtime_state_dir()
    on_exit(fn -> cleanup_launches(runtime_root, root) end)
    assert {:ok, relay} = RelayPort.start(root, "exec python3 #{Aiur.Shell.escape(provider)}", [])
    metadata = Transport.metadata(relay)
    assert_receive {^relay, {:data, {:eol, line}}}, 5_000
    assert {:ok, %{"child" => child, "pgid" => pgid}} = Jason.decode(line)
    assert pgid == metadata.pgid
    assert live?(child)
    refute child in ProcessTree.process_tree(metadata.relay_pid)

    on_exit(fn ->
      ProcessTree.graceful_kill_tree(metadata.relay_pid)
      ProcessTree.graceful_kill_process_group(metadata.pgid)
      for pid <- [metadata.relay_pid, metadata.provider_pid], do: ProcessReaper.unregister({:os_pid, pid})
      if Process.alive?(relay), do: GenServer.stop(relay)
    end)

    {relay, metadata, child}
  end

  defp cleanup_launches(runtime_root, workspace) do
    for manifest <- Path.wildcard(Path.join([runtime_root, "agent-relays", "*", "relay.json"])) do
      with {:ok, body} <- File.read(manifest),
           {:ok, %{"cwd" => ^workspace, "relay_pid" => relay, "pgid" => group}} <- Jason.decode(body) do
        ProcessTree.graceful_kill_tree(relay)
        ProcessTree.graceful_kill_process_group(group)
        ProcessReaper.unregister({:os_pid, relay})
      else
        _ -> :ok
      end
    end
  end

  defp unrelated_process do
    port = Port.open({:spawn_executable, String.to_charlist(System.find_executable("sleep"))}, [:binary, :exit_status, args: [~c"600"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      ProcessTree.graceful_kill_tree(pid)
      ProcessReaper.unregister({:os_pid, pid})
      if Port.info(port), do: Port.close(port)
    end)

    pid
  end

  defp assert_gone(relay, provider, child) do
    deadline = System.monotonic_time(:millisecond) + 8_000
    wait_gone([relay, provider, child], deadline)
    for pid <- [relay, provider, child], do: refute(live?(pid), "process #{pid} survived relay cleanup")
  end

  defp live?(pid) do
    case System.cmd("ps", ["-p", Integer.to_string(pid), "-o", "stat="], stderr_to_stdout: true) do
      {state, 0} -> not String.starts_with?(String.trim(state), "Z")
      {_output, _status} -> false
    end
  end

  defp wait_gone(pids, deadline) do
    if Enum.any?(pids, &live?/1) and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(20)
      wait_gone(pids, deadline)
    end
  end
end
