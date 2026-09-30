defmodule Aiur.AgentTools.MCP.Router do
  @moduledoc false

  @behaviour Plug
  import Plug.Conn

  alias Aiur.AgentTools.{Catalog, MCP}

  @version "2025-06-18"
  @max_body 262_144
  @reply_timeout 30_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "POST", request_path: "/mcp"} = conn, opts) do
    server = Keyword.fetch!(opts, :server)

    with :ok <- validate_origin(conn),
         :ok <- authenticate(conn, server),
         {:ok, body, conn} <- read_json(conn),
         :ok <- validate_request(body),
         :ok <- validate_version(body, conn) do
      respond(conn, body, server)
    else
      {:error, :bad_origin} -> send_resp(conn, 403, "forbidden")
      {:error, :unauthorized} -> send_resp(conn, 401, "unauthorized")
      {:error, :too_large} -> send_resp(conn, 413, "request too large")
      {:error, reason} -> rpc_error(conn, nil, -32_600, Atom.to_string(reason))
    end
  end

  def call(conn, _opts), do: send_resp(conn, 404, "not found")

  defp respond(conn, %{"method" => "initialize", "id" => id}, _server) do
    result = %{
      "protocolVersion" => @version,
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "serverInfo" => %{"name" => "aiur-agent-tools", "version" => "1"}
    }

    rpc_result(conn, id, result)
  end

  defp respond(conn, %{"method" => "notifications/initialized"}, _server),
    do: send_resp(conn, 202, "")

  defp respond(conn, %{"method" => "tools/list", "id" => id}, _server),
    do: rpc_result(conn, id, %{"tools" => Catalog.specs()})

  defp respond(conn, %{"method" => "tools/call", "id" => id, "params" => params}, server)
       when is_map(params) do
    case {params["name"], Map.get(params, "arguments", %{})} do
      {name, args} when is_binary(name) and is_map(args) ->
        with {:ok, ref, owner} <- MCP.dispatch(server, id, name, args),
             {:ok, result} <- await_result(ref, owner) do
          rpc_result(conn, id, tool_result(result))
        else
          {:error, reason} -> rpc_error(conn, id, -32_000, Atom.to_string(reason))
        end

      _ ->
        rpc_error(conn, id, -32_602, "invalid params")
    end
  end

  defp respond(conn, %{"id" => id}, _server), do: rpc_error(conn, id, -32_601, "method not found")
  defp respond(conn, _body, _server), do: rpc_error(conn, nil, -32_600, "invalid request")

  defp await_result(ref, owner) do
    monitor = Process.monitor(owner)

    receive do
      {:aiur_mcp_reply, ^ref, result} ->
        Process.demonitor(monitor, [:flush])
        {:ok, result}

      {:DOWN, ^monitor, :process, ^owner, _} ->
        {:error, :owner_unavailable}
    after
      @reply_timeout ->
        Process.demonitor(monitor, [:flush])
        {:error, :tool_timeout}
    end
  end

  defp tool_result(%{"success" => success, "output" => output})
       when is_boolean(success) and is_binary(output),
       do: %{"content" => [%{"type" => "text", "text" => output}], "isError" => not success}

  defp tool_result({:error, reason}) when reason in [:outcome_uncertain, :conflicting_invocation, :inactive_attempt],
    do: %{"content" => [%{"type" => "text", "text" => Atom.to_string(reason)}], "isError" => true}

  defp tool_result(_other),
    do: %{"content" => [%{"type" => "text", "text" => "tool execution failed"}], "isError" => true}

  defp validate_origin(conn) do
    case get_req_header(conn, "origin") do
      [] ->
        :ok

      [origin] when origin in ["http://localhost", "http://127.0.0.1"] ->
        :ok

      [origin] ->
        uri = URI.parse(origin)

        if uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1"] and
             uri.port == conn.port,
           do: :ok,
           else: {:error, :bad_origin}

      _ ->
        {:error, :bad_origin}
    end
  end

  defp authenticate(conn, server) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> if MCP.authorize(server, token), do: :ok, else: {:error, :unauthorized}
      _ -> {:error, :unauthorized}
    end
  end

  defp read_json(conn) do
    case Plug.Conn.read_body(conn, length: @max_body, read_length: @max_body) do
      {:ok, raw, conn} when byte_size(raw) <= @max_body ->
        case Jason.decode(raw) do
          {:ok, %{} = body} -> {:ok, body, conn}
          _ -> {:error, :invalid_json}
        end

      {:more, _, _} ->
        {:error, :too_large}

      _ ->
        {:error, :invalid_json}
    end
  end

  defp validate_version(%{"method" => "initialize", "params" => %{"protocolVersion" => @version}}, _conn),
    do: :ok

  defp validate_version(%{"method" => "initialize"}, _conn), do: {:error, :unsupported_version}

  defp validate_version(_body, conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] -> :ok
      [@version] -> :ok
      _ -> {:error, :unsupported_version}
    end
  end

  defp validate_request(%{"jsonrpc" => "2.0", "method" => method} = body)
       when is_binary(method) do
    case Map.get(body, "id") do
      id when is_integer(id) or is_binary(id) -> :ok
      nil when method == "notifications/initialized" -> :ok
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_request(_body), do: {:error, :invalid_request}

  defp rpc_result(conn, id, result), do: json(conn, 200, %{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp rpc_error(conn, id, code, message),
    do: json(conn, 200, %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}})

  defp json(conn, status, value) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(value))
  end
end
