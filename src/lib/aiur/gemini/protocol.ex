defmodule Aiur.Gemini.Protocol do
  @moduledoc "ACP v1 wire frames and validation for the native Gemini CLI."

  @spec request(integer(), String.t(), map()) :: map()
  def request(id, method, params),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  @spec initialize(integer(), String.t()) :: map()
  def initialize(id, version),
    do:
      request(id, "initialize", %{
        "protocolVersion" => 1,
        "clientInfo" => %{"name" => "aiur", "version" => version},
        "clientCapabilities" => %{"fs" => %{"readTextFile" => false, "writeTextFile" => false}, "terminal" => false}
      })

  @spec validate_initialize(map()) :: {:ok, map()} | {:error, term()}
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

  @spec session(integer(), String.t(), Path.t(), [map()], String.t() | nil) :: map()
  def session(id, method, workspace, servers, session_id \\ nil) do
    params = %{"cwd" => workspace, "mcpServers" => servers}
    params = if session_id, do: Map.put(params, "sessionId", session_id), else: params
    request(id, method, params)
  end

  @spec prompt(integer(), String.t(), String.t()) :: map()
  def prompt(id, session_id, text),
    do: request(id, "session/prompt", %{"sessionId" => session_id, "prompt" => [%{"type" => "text", "text" => text}]})

  @spec cancel(String.t()) :: map()
  def cancel(session_id),
    do: %{"jsonrpc" => "2.0", "method" => "session/cancel", "params" => %{"sessionId" => session_id}}

  @spec mcp_server(map()) :: map()
  def mcp_server(%{"url" => url, "headers" => headers}) when is_binary(url) and is_map(headers) do
    %{"type" => "http", "name" => "aiur", "url" => url, "headers" => Enum.map(headers, fn {name, value} -> %{"name" => name, "value" => value} end)}
  end
end
