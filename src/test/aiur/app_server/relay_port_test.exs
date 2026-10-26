defmodule Aiur.AppServer.RelayPortTest do
  use Aiur.TestSupport

  alias Aiur.AppServer.{Adapter, RelayPort, Transport}
  alias Aiur.Config.Paths

  test "enabled relay delivers lines, exit status and provider metadata" do
    {:ok, relay} = Adapter.start_port(File.cwd!(), "printf 'ready\\n'; read line; printf '%s\\n' \"$line\"; exit 7")
    assert is_pid(relay)
    metadata = Transport.metadata(relay)
    assert metadata.provider_pid == metadata.pgid
    assert metadata.relay_pid != metadata.provider_pid
    assert File.exists?(Path.join(metadata.directory, "relay.json"))
    assert_receive {^relay, {:data, {:eol, "ready"}}}, 5_000
    :ok = Transport.acknowledge(relay)
    assert Transport.command(relay, "hello\n")
    assert_receive {^relay, {:data, {:eol, "hello"}}}, 5_000
    :ok = Transport.acknowledge(relay)
    assert_receive {^relay, {:exit_status, 7}}, 5_000
    assert Transport.close(relay)
    assert_stopped(metadata.relay_pid)
    assert_stopped(metadata.provider_pid)
  end

  test "close acknowledges a pending frame before stopping the relay" do
    {:ok, relay} = Adapter.start_port(File.cwd!(), "read go; printf 'pending\\n'; sleep 30")

    on_exit(fn ->
      if is_pid(relay) and Process.alive?(relay) do
        _ =
          try do
            Transport.acknowledge(relay)
          rescue
            _ -> :ok
          end

        _ =
          try do
            Transport.close(relay)
          rescue
            _ -> :ok
          end
      end
    end)

    assert is_pid(relay)
    :ok = Transport.manual_acknowledgements(relay)
    assert Transport.command(relay, "go\n")
    assert_receive {^relay, {:data, {:eol, "pending"}}}, 5_000
    assert Transport.metadata(relay).acked_offset == 0

    closer = Task.async(fn -> Transport.close(relay) end)
    result = Task.yield(closer, 1_000)

    if is_nil(result), do: Task.shutdown(closer, :brutal_kill)
    assert result == {:ok, true}
  end

  test "closed relay before acknowledgement stops cleanly with a named reason" do
    root = Path.join("/tmp", "r#{System.pid()}")
    directory = Path.join(root, "relay")
    File.mkdir_p!(directory)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    socket_path = Path.join(directory, "ctl.sock")
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :line, ifaddr: {:local, String.to_charlist(socket_path)}])
    owner = self()
    pid = System.pid() |> String.to_integer()

    peer =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _hello} = :gen_tcp.recv(socket, 0, 1_000)

        :ok =
          :gen_tcp.send(
            socket,
            Jason.encode!(%{
              op: "hello",
              protocol: 1,
              lossy: false,
              relay_pid: pid,
              provider_pid: pid,
              pgid: pid,
              relay_id: "test",
              spawn_nonce: "test",
              journal_end: 0,
              acked_offset: 0
            }) <> "\n"
          )

        {:ok, _attach} = :gen_tcp.recv(socket, 0, 1_000)
        :ok = :gen_tcp.send(socket, Jason.encode!(%{op: "attached"}) <> "\n")
        send(owner, {:relay_peer_attached, self()})

        receive do
          :send_frame -> :ok
        end

        :ok = :gen_tcp.send(socket, Jason.encode!(%{op: "frame", offset: 1, line: "pending"}) <> "\n")
        :ok = :inet.setopts(socket, linger: {true, 0})
        :gen_tcp.close(socket)
        send(owner, {:relay_peer_frame_sent, self()})
      end)

    File.write!(Path.join(directory, "relay.json"), Jason.encode!(%{relay_pid: pid}))
    {:ok, relay} = RelayPort.attach(directory, 1, 0)
    monitor = Process.monitor(relay)
    :ok = RelayPort.call(relay, :manual_acknowledgements)
    assert_receive {:relay_peer_attached, ^peer}, 1_000
    send(peer, :send_frame)
    assert_receive {:relay_peer_frame_sent, ^peer}, 1_000
    assert_receive {^relay, {:data, {:eol, "pending"}}}, 1_000
    caller = spawn(fn -> Transport.acknowledge(relay) end)
    caller_monitor = Process.monitor(caller)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, {:shutdown, {:relay_send_failed, :ack, reason}}}, 1_000
    assert reason in [:closed, :econnreset]
    assert_receive {:DOWN, ^monitor, :process, ^relay, {:shutdown, {:relay_send_failed, :ack, ^reason}}}, 1_000
    :gen_tcp.close(listener)
  end

  test "future guard: disabled relay retains the direct Port path" do
    {:ok, port} = Adapter.start_port(File.cwd!(), "printf 'direct\\n'", fn _ -> :ok end, relay: false)
    assert is_port(port)
    assert_receive {^port, {:data, {:eol, "direct"}}}, 5_000
  end

  test "future guard: missing relay script falls back once to direct Port" do
    workspace = Aiur.TestSupport.tmp_root!("relay-missing-script")
    File.mkdir_p!(workspace)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

    {:ok, port} = Adapter.start_port(workspace, "printf 'fallback\\n'", fn _ -> :ok end, relay_script: "/missing/agent_relay.py")
    assert is_port(port)
    assert_receive {^port, {:data, {:eol, "fallback"}}}, 5_000
    {:ok, root} = Paths.runtime_state_dir()
    assert Path.wildcard(Path.join([root, "agent-relays", "*.#{Paths.sanitize(Path.basename(workspace))}.*"])) == []
  end

  test "future guard: assert_stopped fails while the process is still running" do
    port = Port.open({:spawn_executable, System.find_executable("sleep")}, [:binary, args: ["5"]])
    pid = Port.info(port, :os_pid) |> elem(1)

    try do
      error = assert_raise ExUnit.AssertionError, fn -> assert_stopped(pid, 1) end
      assert error.message =~ "process #{pid} still running"
    after
      Port.close(port)
    end
  end

  test "relay preserves oversized lines and non-UTF8 provider bytes" do
    command = ~S|python3 -c 'import sys; sys.stdout.buffer.write(b"x" * 1048583 + b"\n\xff\n"); sys.stdout.flush()'|
    {:ok, relay} = Adapter.start_port(File.cwd!(), command)
    assert is_pid(relay)
    assert_receive {^relay, {:data, {:noeol, chunk}}}, 5_000
    assert chunk == String.duplicate("x", 1_048_576)
    assert_receive {^relay, {:data, {:eol, "xxxxxxx"}}}, 5_000
    :ok = Transport.acknowledge(relay)
    assert_receive {^relay, {:data, {:eol, <<255>>}}}, 5_000
    :ok = Transport.acknowledge(relay)
    Transport.close(relay)
  end

  test "detach keeps provider alive and a higher generation can reconnect" do
    {:ok, relay} = Adapter.start_port(File.cwd!(), "exec cat")
    assert is_pid(relay)
    assert Transport.command(relay, "first\n")
    assert_receive {^relay, {:data, {:eol, "first"}}}, 5_000
    :ok = Transport.acknowledge(relay)
    metadata = RelayPort.call(relay, :detach)
    assert metadata.acked_offset == 6
    assert Aiur.ProcessTree.process_alive?(metadata.provider_pid)
    assert {:error, _} = RelayPort.attach(metadata.directory, metadata.generation, metadata.acked_offset)
    assert {:ok, next} = RelayPort.attach(metadata.directory, metadata.generation + 1, metadata.acked_offset)
    assert Transport.command(next, "second\n")
    assert_receive {^next, {:data, {:eol, "second"}}}, 5_000
    :ok = Transport.acknowledge(next)
    refute_receive {^next, {:data, {:eol, "first"}}}, 100
    Transport.close(next)
  end

  test "generation is stable per boot and advances on the next boot identity" do
    {:ok, root} = Paths.runtime_state_dir()
    root = Path.join(root, "agent-relays")
    generation = RelayPort.generation(root)
    assert RelayPort.generation(root) == generation
    Aiur.Boot.remark()
    assert RelayPort.generation(root) == generation + 1
  end

  defp assert_stopped(pid, attempts \\ 50)
  defp assert_stopped(pid, 0), do: flunk("process #{pid} still running")

  defp assert_stopped(pid, attempts) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        if stat |> String.split(") ") |> List.last() |> String.starts_with?("Z ") do
          :ok
        else
          Process.sleep(10)
          assert_stopped(pid, attempts - 1)
        end

      {:error, :enoent} ->
        :ok

      {:error, :esrch} ->
        :ok
    end
  end
end
