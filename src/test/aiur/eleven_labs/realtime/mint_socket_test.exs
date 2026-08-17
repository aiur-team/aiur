defmodule Aiur.ElevenLabs.Realtime.MintSocketTest do
  @moduledoc """
  The Mint transport against a websocket server on loopback.

  `Aiur.ElevenLabs.Realtime` is tested against a fake transport, which is the
  right seam for the protocol rules. This module is the one place that drives
  `Mint.WebSocket`, and its bugs are precisely the ones a fake cannot show: they
  live in how Mint batches the upgrade response.

  The server here is hand-rolled rather than Bandit, for two reasons. It can put
  the 101 and the first frame in a **single** `:gen_tcp.send`, which is the
  condition the regression below needs and which a real server will not
  reproduce on demand. And it costs a process and a listen socket, so it does
  not add a server boot to the critical path of an assertion — a Bandit-backed
  version of this file passed alone and timed out under a loaded full-suite run,
  which is a flake, not a test.
  """

  use ExUnit.Case, async: true

  alias Aiur.ElevenLabs.Realtime.MintSocket

  # A liveness bound, not a performance assertion.
  #
  # ExUnit's default `assert_receive` window is 100 ms, which is a wall-clock
  # deadline standing in for synchronisation: it comfortably contains a TCP
  # accept, handshake and decode on an idle machine, and does not when the full
  # suite has 32 cases in flight. These tests passed alone and failed in the
  # suite, which is the definition of a flake — the same shape as #1983, where a
  # 300 ms deadline had to contain 126-308 ms of real work.
  #
  # Nothing here asserts that delivery is *fast*; every assertion is that it
  # happens at all. So the bound is sized to contain the work under load with
  # room to spare, where it can only fire if something is genuinely broken.
  @delivered 5_000

  defmodule Server do
    @moduledoc """
    A minimal RFC 6455 server: completes the handshake, writes a greeting frame
    in the same segment, then echoes whatever it is sent.

    It speaks only the short-payload frame form, which is all these tests need.
    """

    @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    @spec start(binary()) :: {:ok, :inet.port_number()}
    def start(greeting) do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listen)
      test = self()
      spawn_link(fn -> accept(listen, greeting, test) end)
      {:ok, port}
    end

    defp accept(listen, greeting, test) do
      {:ok, socket} = :gen_tcp.accept(listen)
      request = read_request(socket, "")
      send(test, {:server_request_headers, request})

      # One `send`, so the 101 and the first frame share a segment. This is what
      # ElevenLabs does — `session_started` goes out the moment the upgrade is
      # accepted — and it is what makes Mint return `[:status, :headers, :data,
      # :done]` as a single list.
      :ok = :gen_tcp.send(socket, handshake(websocket_key(request)) <> frame(greeting))
      echo(socket, "")
    end

    defp echo(socket, buffer) do
      case take_frame(buffer) do
        {:ok, payload, rest} ->
          :ok = :gen_tcp.send(socket, frame("echo:" <> payload))
          echo(socket, rest)

        :more ->
          case :gen_tcp.recv(socket, 0, 30_000) do
            {:ok, data} -> echo(socket, buffer <> data)
            {:error, _closed} -> :ok
          end
      end
    end

    # Client frames are masked; the payload is XORed with the 4-byte key.
    defp take_frame(<<_fin_opcode, 1::1, length::7, mask::binary-size(4), rest::binary>>) when byte_size(rest) >= length do
      <<payload::binary-size(length), remainder::binary>> = rest
      {:ok, unmask(payload, mask), remainder}
    end

    defp take_frame(_buffer), do: :more

    defp unmask(payload, mask) do
      mask_bytes = :binary.bin_to_list(mask)

      payload
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.map(fn {byte, index} -> Bitwise.bxor(byte, Enum.at(mask_bytes, rem(index, 4))) end)
      |> :binary.list_to_bin()
    end

    defp read_request(socket, acc) do
      if String.contains?(acc, "\r\n\r\n") do
        acc
      else
        {:ok, data} = :gen_tcp.recv(socket, 0, 30_000)
        read_request(socket, acc <> data)
      end
    end

    defp websocket_key(request) do
      [key] =
        for line <- String.split(request, "\r\n"),
            [name, value] <- [String.split(line, ": ", parts: 2)],
            String.downcase(name) == "sec-websocket-key",
            do: String.trim(value)

      Base.encode64(:crypto.hash(:sha, key <> @guid))
    end

    defp handshake(accept) do
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
        "Sec-WebSocket-Accept: #{accept}\r\n\r\n"
    end

    # Unmasked server text frame, short-payload form.
    defp frame(payload) when byte_size(payload) < 126, do: <<0x81, byte_size(payload)>> <> payload
  end

  # The regression this file exists for.
  #
  # Mint returns `[:status, :headers, :data, :done]` in one list when the
  # server's first frame shares the 101's segment. The websocket only comes into
  # existence at `:done`, so decoding strictly in arrival order dropped that
  # frame. Against ElevenLabs that frame is `session_started`: the readiness gate
  # never opened, every held word queued in the backlog and was discarded, and
  # the microphone looked connected while transcribing nothing.
  test "delivers a frame that shares the upgrade's response batch" do
    {:ok, port} = Server.start("session_started")

    {:ok, _socket} = MintSocket.start(self(), url(port), [])

    assert_receive {:elevenlabs_transport, :text, "session_started"}, @delivered
  end

  test "delivers frames that arrive after the upgrade" do
    {:ok, port} = Server.start("session_started")
    {:ok, socket} = MintSocket.start(self(), url(port), [])
    assert_receive {:elevenlabs_transport, :text, "session_started"}, @delivered

    assert :ok = MintSocket.send_text(socket, "audio-frame")

    assert_receive {:elevenlabs_transport, :text, "echo:audio-frame"}, @delivered
  end

  test "carries the credential in a request header, never in the url" do
    {:ok, port} = Server.start("session_started")

    {:ok, _socket} = MintSocket.start(self(), url(port), [{"xi-api-key", "xi-secret"}])

    assert_receive {:server_request_headers, request}, @delivered
    assert request =~ "xi-api-key: xi-secret"
    # The request line is the part that reaches an access log.
    [request_line | _rest] = String.split(request, "\r\n")
    refute request_line =~ "xi-secret"
    refute request_line =~ "token"
  end

  test "refuses to send before the upgrade completes" do
    {:ok, port} = Server.start("session_started")
    {:ok, socket} = MintSocket.start(self(), url(port), [])

    # Racing the handshake is the point: a session that pushes audio the instant
    # it starts must get a refusal it can handle, not a crash.
    assert MintSocket.send_text(socket, "early") in [:ok, {:error, :not_ready}]
  end

  test "reports a server that never speaks websocket rather than hanging" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      :ok = :gen_tcp.send(socket, "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n\r\n")
    end)

    {:ok, _socket} = MintSocket.start(self(), "ws://127.0.0.1:#{port}/realtime", [])

    assert_receive {:elevenlabs_transport, :error, _reason}, @delivered
  end

  test "stops when the session that opened it stops" do
    {:ok, port} = Server.start("session_started")
    session = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, socket} = MintSocket.start(session, url(port), [])
    reference = Process.monitor(socket)

    Process.exit(session, :kill)

    assert_receive {:DOWN, ^reference, :process, ^socket, _reason}, @delivered
  end

  test "refuses a scheme it cannot speak" do
    assert {:error, _reason} = MintSocket.start(self(), "ftp://127.0.0.1/realtime", [])
  end

  test "closing twice is safe" do
    {:ok, port} = Server.start("session_started")
    {:ok, socket} = MintSocket.start(self(), url(port), [])

    assert :ok = MintSocket.close(socket)
    assert :ok = MintSocket.close(socket)
  end

  defp url(port), do: "ws://127.0.0.1:#{port}/realtime"
end
