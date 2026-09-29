defmodule Aiur.Gemini.Protocol do
  @moduledoc "ACP v1 wire frames and validation for the native Gemini CLI."

  def request(id, method, params),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  def initialize(id, version),
    do:
      request(id, "initialize", %{
        "protocolVersion" => 1,
        "clientInfo" => %{"name" => "aiur", "version" => version},
        "clientCapabilities" => %{"fs" => %{"readTextFile" => false, "writeTextFile" => false}, "terminal" => false}
      })

  def validate_initialize(%{"protocolVersion" => 1, "agentCapabilities" => capabilities})
      when is_map(capabilities) do
    cond do
      get_in(capabilities, ["mcpCapabilities", "http"]) != true -> {:error, :gemini_http_mcp_unsupported}
      capabilities["loadSession"] != true -> {:error, :gemini_session_load_unsupported}
      true -> {:ok, capabilities}
    end
  end

  def validate_initialize(%{"protocolVersion" => version}), do: {:error, {:unsupported_acp_version, version}}
  def validate_initialize(_), do: {:error, :invalid_acp_handshake}

  def session(id, method, workspace, servers, session_id \\ nil) do
    params = %{"cwd" => workspace, "mcpServers" => servers}
    params = if session_id, do: Map.put(params, "sessionId", session_id), else: params
    request(id, method, params)
  end

  def prompt(id, session_id, text),
    do: request(id, "session/prompt", %{"sessionId" => session_id, "prompt" => [%{"type" => "text", "text" => text}]})

  def cancel(session_id),
    do: %{"jsonrpc" => "2.0", "method" => "session/cancel", "params" => %{"sessionId" => session_id}}

  def mcp_server(%{"url" => url, "headers" => headers}) when is_binary(url) and is_map(headers) do
    %{"type" => "http", "name" => "aiur", "url" => url, "headers" => Enum.map(headers, fn {name, value} -> %{"name" => name, "value" => value} end)}
  end
end
