defmodule Aiur.AppServer.RelayPortAckFailureTest do
  use Aiur.TestSupport

  alias Aiur.AppServer.{RelayPort, Transport}

  test "closed relay before acknowledgement stops cleanly with a named reason" do
    root = Path.join("/tmp", "r#{System.pid()}")
    directory = Path.join(root, "relay")
    File.mkdir_p!(directory)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    socket_path = Path.join(directory, "ctl.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :line,
        ifaddr: {:local, String.to_charlist(socket_path)}
      ])

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

        :ok =
          :gen_tcp.send(socket, Jason.encode!(%{op: "frame", offset: 1, line: "pending"}) <> "\n")

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
    {caller, caller_monitor} = spawn_monitor(fn -> Transport.acknowledge(relay) end)

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, {:shutdown, {:relay_send_failed, :ack, reason}}},
                   1_000

    assert reason in [:closed, :econnreset]

    assert_receive {:DOWN, ^monitor, :process, ^relay, {:shutdown, {:relay_send_failed, :ack, ^reason}}},
                   1_000

    :gen_tcp.close(listener)
  end

  test "automatic acknowledgement logs and stops when peer closes before ack" do
    import ExUnit.CaptureLog

    root = Path.join("/tmp", "r#{System.pid()}-auto")
    directory = Path.join(root, "relay")
    File.mkdir_p!(directory)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    socket_path = Path.join(directory, "ctl.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :line,
        ifaddr: {:local, String.to_charlist(socket_path)}
      ])

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
              relay_id: "test-auto",
              spawn_nonce: "test-auto",
              journal_end: 0,
              acked_offset: 0
            }) <> "\n"
          )

        {:ok, _attach} = :gen_tcp.recv(socket, 0, 1_000)
        :ok = :gen_tcp.send(socket, Jason.encode!(%{op: "attached"}) <> "\n")
        send(owner, {:relay_auto_peer_attached, self()})

        receive do
          :send_frame -> :ok
        end

        :ok =
          :gen_tcp.send(socket, Jason.encode!(%{op: "frame", offset: 1, line: "pending"}) <> "\n")

        :ok = :inet.setopts(socket, linger: {true, 0})
        :gen_tcp.close(socket)
        send(owner, {:relay_auto_peer_closed, self()})
      end)

    File.write!(Path.join(directory, "relay.json"), Jason.encode!(%{relay_pid: pid}))

    log =
      capture_log(fn ->
        {:ok, relay} = RelayPort.attach(directory, 1, 0)
        monitor = Process.monitor(relay)
        assert_receive {:relay_auto_peer_attached, ^peer}, 1_000
        :ok = :sys.suspend(relay)
        send(peer, :send_frame)
        assert_receive {:relay_auto_peer_closed, ^peer}, 1_000
        :ok = :sys.resume(relay)

        assert_receive {:DOWN, ^monitor, :process, ^relay, {:shutdown, {:relay_send_failed, :ack, reason}}},
                       1_000

        assert reason in [:closed, :econnreset]
        refute_receive {^relay, {:exit_status, 1}}, 50
      end)

    assert log =~ "relay acknowledgement failed: {:relay_send_failed, :ack,"
    :gen_tcp.close(listener)
  end
end
