defmodule Aiur.AgentTools.MCPTest do
  use ExUnit.Case, async: false

  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.AgentTools.MCP
  alias Aiur.AgentTools.MCP.Router

  setup do
    {:ok, gateway} = MCP.start_link(owner: self())
    %{gateway: gateway, connection: Map.put(MCP.connection(gateway), :gateway, gateway)}
  end

  test "a scoped gateway initializes, lists tools and executes in its owner", %{gateway: gateway, connection: connection} do
    assert {:ok, binding} = MCP.bind(gateway, "attempt-1")

    assert {:ok, %{"result" => %{"protocolVersion" => "2025-06-18"}}} =
             post(connection, 1, "initialize", %{"protocolVersion" => "2025-06-18"})

    assert {:ok, %{"result" => %{"tools" => tools}}} = post(connection, 2, "tools/list", %{})
    assert Enum.any?(tools, &(&1["name"] == "emit_event"))

    caller = self()
    request = Task.async(fn -> post(connection, 3, "tools/call", %{"name" => "emit_event", "arguments" => %{}}) end)
    receive_barrier({:aiur_mcp_call, ^gateway, _, _, ^binding, _, "emit_event", %{} = _args} = message)

    assert :ok =
             MCP.execute_request(gateway, message, fn name, args ->
               assert self() == caller
               assert name == "emit_event"
               assert args == %{}
               %{"success" => true, "output" => "done"}
             end)

    assert {:ok, %{"result" => %{"content" => [%{"text" => "done"}], "isError" => false}}} = Task.await(request, :infinity)
  end

  test "requests are denied before binding and after unbinding", %{gateway: gateway, connection: connection} do
    assert {:ok, %{"error" => %{"message" => "inactive_attempt"}}} =
             post(connection, 1, "tools/call", %{"name" => "emit_event", "arguments" => %{}})

    assert {:ok, binding} = MCP.bind(gateway, "attempt-1")
    assert :ok = MCP.unbind(gateway, binding)

    assert {:ok, %{"error" => %{"message" => "inactive_attempt"}}} =
             post(connection, 2, "tools/call", %{"name" => "emit_event", "arguments" => %{}})
  end

  test "revoking an attempt fences a tool call already queued to its owner", %{gateway: gateway, connection: connection} do
    assert {:ok, binding} = MCP.bind(gateway, "revoked-attempt")
    request = Task.async(fn -> post(connection, 31, "tools/call", %{"name" => "emit_event", "arguments" => %{}}) end)
    receive_barrier({:aiur_mcp_call, ^gateway, _, _, ^binding, _, _, _} = message)

    assert :ok = MCP.unbind(gateway, binding)
    assert :ok = MCP.execute_request(gateway, message, fn _, _ -> flunk("revoked tool must not execute") end)

    assert {:ok, %{"result" => %{"content" => [%{"text" => "inactive_attempt"}], "isError" => true}}} =
             Task.await(request, :infinity)
  end

  test "replaying an identical tool request returns the result and executes once", %{gateway: gateway, connection: connection} do
    assert {:ok, binding} = MCP.bind(gateway, "replay-attempt")
    calls = :atomics.new(1, [])

    for _ <- 1..2 do
      request = Task.async(fn -> post(connection, 21, "tools/call", %{"name" => "emit_event", "arguments" => %{"value" => 42}}) end)
      receive_barrier({:aiur_mcp_call, ^gateway, _, _, ^binding, _, "emit_event", %{"value" => 42}} = message)

      assert :ok =
               MCP.execute_request(gateway, message, fn _, _ ->
                 :atomics.add(calls, 1, 1)
                 %{"success" => true, "output" => "durable result"}
               end)

      assert {:ok, %{"result" => %{"content" => [%{"text" => "durable result"}], "isError" => false}}} = Task.await(request, :infinity)
    end

    assert :atomics.get(calls, 1) == 1
  end

  test "missing bearer and foreign Origin are denied", %{connection: connection} do
    assert {:http, 401, _} = post(connection, 1, "tools/list", %{}, authorization: nil)
    assert {:http, 403, _} = post(connection, 1, "tools/list", %{}, origin: "https://evil.example")
  end

  test "the loopback listener answers an authenticated HTTP request", %{connection: connection} do
    :inets.start()
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}})

    request =
      {String.to_charlist(connection["url"]), [{~c"authorization", String.to_charlist(connection["headers"]["Authorization"])}], ~c"application/json", body}

    assert {:ok, {{_, 200, _}, _, response}} = :httpc.request(:post, request, [], body_format: :binary)
    assert %{"result" => %{"tools" => tools}} = Jason.decode!(response)
    assert Enum.any?(tools, &(&1["name"] == "emit_event"))
  end

  test "a request id cannot cross attempts or change arguments", %{gateway: gateway, connection: connection} do
    assert {:ok, first} = MCP.bind(gateway, "attempt-1")
    request = Task.async(fn -> post(connection, 7, "tools/call", %{"name" => "emit_event", "arguments" => %{"x" => 1}}) end)
    receive_barrier({:aiur_mcp_call, ^gateway, _, _, ^first, _, _, _} = message)
    assert :ok = MCP.execute_request(gateway, message, fn _, _ -> %{"success" => true, "output" => "once"} end)
    assert {:ok, %{"result" => _}} = Task.await(request, :infinity)

    assert {:ok, %{"error" => %{"message" => "conflicting_invocation"}}} =
             post(connection, 7, "tools/call", %{"name" => "emit_event", "arguments" => %{"x" => 2}})

    assert :ok = MCP.unbind(gateway, first)
    assert {:ok, _second} = MCP.bind(gateway, "attempt-2")

    assert {:ok, %{"error" => %{"message" => "stale_invocation"}}} =
             post(connection, 7, "tools/call", %{"name" => "emit_event", "arguments" => %{"x" => 1}})
  end

  defp post(connection, id, method, params, opts \\ []) do
    headers =
      case Keyword.get(opts, :authorization, connection["headers"]["Authorization"]) do
        nil -> []
        value -> [{"authorization", value}]
      end

    headers =
      case Keyword.get(opts, :origin) do
        nil -> headers
        value -> [{"origin", value} | headers]
      end

    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    uri = URI.parse(connection["url"])
    conn = Plug.Test.conn(:post, uri.path, body)
    conn = %{conn | port: uri.port}
    conn = Enum.reduce(headers, conn, fn {key, value}, acc -> Plug.Conn.put_req_header(acc, key, value) end)
    conn = Router.call(conn, Router.init(server: connection.gateway))

    case conn.status do
      200 -> {:ok, Jason.decode!(conn.resp_body)}
      status -> {:http, status, conn.resp_body}
    end
  end
end
