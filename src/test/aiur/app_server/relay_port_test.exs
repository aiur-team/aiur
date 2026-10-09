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
    assert Transport.command(relay, "hello\n")
    assert_receive {^relay, {:data, {:eol, "hello"}}}, 5_000
    assert_receive {^relay, {:exit_status, 7}}, 5_000
    assert Transport.close(relay)
    assert_stopped(metadata.relay_pid)
    assert_stopped(metadata.provider_pid)
  end

  test "future guard: disabled relay retains the direct Port path" do
    {:ok, port} = Adapter.start_port(File.cwd!(), "printf 'direct\\n'", fn _ -> :ok end, relay: false)
    assert is_port(port)
    assert_receive {^port, {:data, {:eol, "direct"}}}, 5_000
  end

  test "future guard: missing relay script falls back once to direct Port" do
    {:ok, port} = Adapter.start_port(File.cwd!(), "printf 'fallback\\n'", fn _ -> :ok end, relay_script: "/missing/agent_relay.py")
    assert is_port(port)
    assert_receive {^port, {:data, {:eol, "fallback"}}}, 5_000
  end

  test "relay preserves oversized lines and non-UTF8 provider bytes" do
    command = ~S|python3 -c 'import sys; sys.stdout.buffer.write(b"x" * 1048583 + b"\n\xff\n"); sys.stdout.flush()'|
    {:ok, relay} = Adapter.start_port(File.cwd!(), command)
    assert is_pid(relay)
    assert_receive {^relay, {:data, {:noeol, chunk}}}, 5_000
    assert chunk == String.duplicate("x", 1_048_576)
    assert_receive {^relay, {:data, {:eol, "xxxxxxx"}}}, 5_000
    assert_receive {^relay, {:data, {:eol, <<255>>}}}, 5_000
    Transport.close(relay)
  end

  test "detach keeps provider alive and a higher generation can reconnect" do
    {:ok, relay} = Adapter.start_port(File.cwd!(), "exec cat")
    assert is_pid(relay)
    assert Transport.command(relay, "first\n")
    assert_receive {^relay, {:data, {:eol, "first"}}}, 5_000
    metadata = RelayPort.call(relay, :detach)
    assert metadata.acked_offset == 6
    assert Aiur.ProcessTree.process_alive?(metadata.provider_pid)
    assert {:error, _} = RelayPort.attach(metadata.directory, metadata.generation, metadata.acked_offset)
    assert {:ok, next} = RelayPort.attach(metadata.directory, metadata.generation + 1, metadata.acked_offset)
    assert Transport.command(next, "second\n")
    assert_receive {^next, {:data, {:eol, "second"}}}, 5_000
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
    end
  end
end
