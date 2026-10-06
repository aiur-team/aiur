defmodule Aiur.Muse.TransportTest do
  use ExUnit.Case, async: true

  alias Aiur.Muse.Transport

  test "fragmented frames retain UTF-8 bytes and reject non-protocol output without echoing it" do
    frame = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "item/delta", "params" => %{"delta" => "λ"}})
    split = byte_size(frame) - 5
    <<first::binary-size(split), last::binary>> = frame
    assert {:more, ^first} = Transport.decode_chunk("", {:noeol, first})
    assert {:ok, %{"params" => %{"delta" => "λ"}}} = Transport.decode_chunk(first, {:eol, last})
    assert {:error, :invalid_msp_frame} = Transport.decode_chunk("", {:eol, "secret diagnostic"})
    assert {:error, :invalid_msp_frame} = Transport.decode_chunk("", {:eol, ~s({"result":{}})})
  end

  test "fragment accumulation is bounded before JSON decoding" do
    oversized = :binary.copy("x", 4_194_304)
    assert {:error, :frame_too_large} = Transport.decode_chunk(oversized, {:noeol, "x"})
  end

  test "a real subprocess response preserves intervening native notifications" do
    port =
      fixture_port("""
      import sys,json
      request=json.loads(sys.stdin.readline())
      print(json.dumps({'jsonrpc':'2.0','method':'session/started','params':{'sessionId':'native-session'}}),flush=True)
      print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':{'grantedCapabilities':['sessionMcp']}}),flush=True)
      sys.stdin.read()
      """)

    owner = self()
    request = %{"jsonrpc" => "2.0", "id" => 7, "method" => "initialize", "params" => %{}}

    assert {:ok, %{"grantedCapabilities" => ["sessionMcp"]}} =
             Transport.request(port, request, 5_000, &send(owner, {:notification, &1}))

    assert_received {:notification, %{"method" => "session/started", "params" => %{"sessionId" => "native-session"}}}
  end

  test "a disconnected provider reports its exit instead of accepting a write as success" do
    port = fixture_port("import sys; sys.stdin.readline(); sys.exit(23)")
    frame = %{"jsonrpc" => "2.0", "id" => 8, "method" => "turn/start", "params" => %{}}
    assert {:error, {:port_exit, 23}} = Transport.request(port, frame, 5_000)
  end

  test "remote workspaces are rejected before process launch" do
    assert {:error, :remote_worker_unsupported} = Transport.start("/missing", "muse serve", worker_host: "worker")
    assert {:error, :workspace_not_found} = Transport.start("/missing-aiur-muse-workspace", "muse serve")
  end

  defp fixture_port(script) do
    python = System.find_executable("python3") || raise "python3 is required for transport boundary tests"
    port = Port.open({:spawn_executable, python}, [:binary, :exit_status, args: ["-u", "-c", script], line: 1_048_576])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    port
  end
end
