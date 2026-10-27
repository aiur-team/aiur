defmodule VoiceConverse.Provider.ElevenLabsAgents.MintSocketTest do
  use ExUnit.Case, async: false

  import Bitwise
  import ExUnit.CaptureLog
  import ExUnit.Assertions, except: [assert_receive: 1]

  alias VoiceConverse.Provider.ElevenLabsAgents.MintSocket

  @transport_message :elevenlabs_agents_transport

  defmacro assert_receive(pattern) do
    quote do
      assert_receive(unquote(pattern), 1_000)
    end
  end

  test "completes a local 101 upgrade, sends text, and does not retain the signed URL" do
    {listener, port} = listen()
    test_pid = self()

    server =
      spawn(fn ->
        socket = accept_upgrade(listener)
        frame = recv_client_frame(socket)
        :ok = :gen_tcp.send(socket, server_frame(1, "reply"))
        send(test_pid, {:server_frame, frame})
        receive(do: (:finish -> :gen_tcp.close(socket)))
      end)

    url = "ws://127.0.0.1:#{port}/conversation?token=never-in-state"
    {:ok, socket} = MintSocket.start(self(), url, [])
    assert :ok = MintSocket.send_text(socket, "hello")

    assert_receive {:server_frame, %{opcode: 1, payload: "hello"}}
    assert_receive {@transport_message, :text, "reply"}
    refute inspect(:sys.get_state(socket)) =~ url

    assert :ok = MintSocket.close(socket)
    send(server, :finish)
  end

  test "reports a non-101 upgrade as a transport error" do
    {listener, port} = listen()

    Task.start(fn ->
      {:ok, client} = :gen_tcp.accept(listener)
      _request = recv_headers(client)
      :ok = :gen_tcp.send(client, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
      :gen_tcp.close(client)
    end)

    {:ok, socket} = MintSocket.start(self(), "ws://127.0.0.1:#{port}/forbidden", [])

    assert_receive {@transport_message, :error, :transport}, 1_000
    assert {:error, :send_failed} = MintSocket.send_text(socket, "late")
  end

  test "replies to ping and echoes the peer close code before closing" do
    {listener, port} = listen()
    test_pid = self()

    spawn(fn ->
      socket = accept_upgrade(listener)
      _ready = recv_client_frame(socket)
      :ok = :gen_tcp.send(socket, server_frame(9, "ping-data"))
      pong = recv_client_frame(socket)
      :ok = :gen_tcp.send(socket, server_frame(8, <<1001::16, "going away">>))
      close = recv_client_frame(socket)
      send(test_pid, {:server_frames, pong, close})
      :gen_tcp.close(socket)
    end)

    {:ok, socket} = MintSocket.start(self(), "ws://127.0.0.1:#{port}/conversation", [])
    assert :ok = MintSocket.send_text(socket, "ready")

    assert_receive {:server_frames, %{opcode: 10, payload: "ping-data"},
                    %{opcode: 8, payload: <<1001::16, "going away">>}}

    assert_receive {@transport_message, :closed, 1001}
  end

  test "reports a socket close after a successful upgrade as a transport error" do
    {listener, port} = listen()
    test_pid = self()

    spawn(fn ->
      socket = accept_upgrade(listener)
      _frame = recv_client_frame(socket)
      send(test_pid, :server_received_frame)
      :gen_tcp.close(socket)
    end)

    {:ok, socket} = MintSocket.start(self(), "ws://127.0.0.1:#{port}/conversation", [])
    assert :ok = MintSocket.send_text(socket, "ready")

    assert_receive :server_received_frame
    assert_receive {@transport_message, :error, :transport}, 1_000
  end

  test "reports an invalid websocket error frame from a local server" do
    {listener, port} = listen()

    spawn(fn ->
      socket = accept_upgrade(listener)
      _frame = recv_client_frame(socket)
      :ok = :gen_tcp.send(socket, server_frame(3, "invalid-opcode"))
      :gen_tcp.close(socket)
    end)

    {:ok, socket} = MintSocket.start(self(), "ws://127.0.0.1:#{port}/conversation", [])
    assert :ok = MintSocket.send_text(socket, "ready")

    assert_receive {@transport_message, :error, :transport}, 1_000
  end

  test "returns a send failure after the real peer disconnects" do
    {listener, port} = listen()
    test_pid = self()

    spawn(fn ->
      socket = accept_upgrade(listener)
      _frame = recv_client_frame(socket)
      :ok = :inet.setopts(socket, linger: {true, 0})
      :gen_tcp.close(socket)
      send(test_pid, :peer_closed)
    end)

    {:ok, socket} = MintSocket.start(self(), "ws://127.0.0.1:#{port}/conversation", [])
    assert :ok = MintSocket.send_text(socket, "ready")
    assert_receive :peer_closed

    result =
      try do
        MintSocket.send_text(socket, "late")
      catch
        :exit, _reason -> :exited
      end

    assert {:error, :send_failed} = result
    assert_receive {@transport_message, :error, :transport}, 1_000
  end

  test "close sends a websocket close frame" do
    {listener, port} = listen()
    test_pid = self()

    spawn(fn ->
      socket = accept_upgrade(listener)
      _ready = recv_client_frame(socket)
      send(test_pid, :server_ready)
      close = recv_client_frame(socket)
      send(test_pid, {:server_close, close})
      :gen_tcp.close(socket)
    end)

    {:ok, socket} = MintSocket.start(self(), "ws://127.0.0.1:#{port}/conversation", [])
    assert :ok = MintSocket.send_text(socket, "ready")
    assert_receive :server_ready
    assert :ok = MintSocket.close(socket)
    assert_receive {:server_close, %{opcode: 8, payload: <<1000::16>>}}
  end

  test "TLS options verify peers, include system CAs, and preserve hostname checking" do
    options = MintSocket.tls_options("api.elevenlabs.io")

    assert Keyword.fetch!(options, :verify) == :verify_peer
    assert Keyword.fetch!(options, :cacerts) == :public_key.cacerts_get()
    assert Keyword.fetch!(options, :server_name_indication) == ~c"api.elevenlabs.io"
    assert is_function(options[:customize_hostname_check][:match_fun])
  end

  test "passes TLS transport options to the HTTPS connect call" do
    test_pid = self()

    connect_fun = fn scheme, host, port, options ->
      send(test_pid, {:connect, scheme, host, port, options})
      {:error, :test_connection}
    end

    {:ok, _socket} =
      MintSocket.start(self(), "wss://api.elevenlabs.io/conversation?token=never-in-state", [],
        connect_fun: connect_fun
      )

    assert_receive {:connect, :https, "api.elevenlabs.io", 443, options}
    tls = Keyword.fetch!(options, :transport_opts)

    assert Keyword.fetch!(options, :protocols) == [:http1]
    assert Keyword.fetch!(tls, :verify) == :verify_peer
    assert Keyword.fetch!(tls, :cacerts) == :public_key.cacerts_get()
    assert Keyword.fetch!(tls, :server_name_indication) == ~c"api.elevenlabs.io"
    assert is_function(tls[:customize_hostname_check][:match_fun])
    assert_receive {@transport_message, :error, :transport}
  end

  test "rejects non-loopback unencrypted signed URLs" do
    assert {:error, :unsupported_url} = MintSocket.start(self(), "ws://api.elevenlabs.io/conversation", [])
    assert {:error, :unsupported_url} = MintSocket.start(self(), "http://api.elevenlabs.io/conversation", [])
  end

  test "redacts the signed URL when the connection worker crashes" do
    signed_url = "wss://api.elevenlabs.io/conversation?token=never-in-crash-report"

    log =
      capture_log(fn ->
        {:ok, socket} = MintSocket.start(self(), signed_url, [], connect_fun: fn _, _, _, _ -> raise "test crash" end)
        monitor = Process.monitor(socket)
        assert_receive {:DOWN, ^monitor, :process, ^socket, _reason}
      end)

    refute log =~ signed_url
    refute log =~ "never-in-crash-report"
  end

  defp listen do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    {listener, port}
  end

  defp accept_upgrade(listener) do
    {:ok, socket} = :gen_tcp.accept(listener)
    request = recv_headers(socket)
    [_, key] = Regex.run(~r/sec-websocket-key: (.+)\r/i, request)

    accept =
      :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
      |> Base.encode64()

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\n" <>
          "Connection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
      )

    socket
  end

  defp recv_headers(socket, received \\ "") do
    if String.contains?(received, "\r\n\r\n") do
      received
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
      recv_headers(socket, received <> data)
    end
  end

  defp recv_client_frame(socket) do
    {:ok, <<_fin::1, _reserved::3, opcode::4, 1::1, size::7>>} = :gen_tcp.recv(socket, 2, 2_000)
    {:ok, <<mask::binary-size(4), masked::binary-size(size)>>} = :gen_tcp.recv(socket, 4 + size, 2_000)

    payload =
      masked
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.map(fn {byte, index} -> bxor(byte, :binary.at(mask, rem(index, 4))) end)
      |> :erlang.list_to_binary()

    %{opcode: opcode, payload: payload}
  end

  defp server_frame(opcode, payload) do
    <<1::1, 0::3, opcode::4, 0::1, byte_size(payload)::7, payload::binary>>
  end
end
