defmodule Aiur.Claude.CodingAgent.Handshake do
  @moduledoc false
  require Logger
  alias Aiur.AgentTools.Catalog
  alias Aiur.AppServer.{Messages, Rpc}
  alias Aiur.Claude.CodingAgent
  alias Aiur.Config

  @minimum_version "1.3.0"

  @spec minimum_version() :: String.t()
  def minimum_version, do: @minimum_version

  @spec start(port() | pid(), Path.t()) :: {:ok, String.t(), map()} | {:error, term()}
  def start(port, workspace) do
    with :ok <- CodingAgent.send_frame(port, Messages.initialize_frame()),
         {:ok, result} <- await(port, Messages.initialize_id()),
         :ok <- CodingAgent.send_frame(port, Messages.initialized_frame()) do
      start_thread(port, workspace, capability(result))
    end
  end

  @spec capability(map()) :: map()
  def capability(result) do
    if Config.decisions_native_capture?(:claude) do
      case version_reason(get_in(result, ["server", "version"])) do
        nil ->
          %{native_question: :deferred, reason: nil}

        reason ->
          Logger.warning("Claude native questions disabled: #{reason}; requires aiur-claude >= #{@minimum_version}")
          %{native_question: :none, reason: reason}
      end
    else
      %{native_question: :none, reason: :gate_off}
    end
  end

  defp version_reason(version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, parsed} -> if Version.compare(parsed, @minimum_version) == :lt, do: :sibling_too_old
      :error -> :version_unknown
    end
  end

  defp version_reason(_unknown), do: :version_unknown

  defp start_thread(port, workspace, capability) do
    params = %{"permissionMode" => Aiur.Claude.Config.permission_mode(), "cwd" => Path.expand(workspace), "dynamicTools" => Catalog.specs()}
    params = if capability.native_question == :deferred, do: Map.put(params, "nativeQuestions", true), else: params

    with :ok <- CodingAgent.send_frame(port, %{"method" => "thread/start", "id" => 2, "params" => params}),
         {:ok, result} <- await(port, 2) do
      case result do
        %{"thread" => %{"id" => id}} when is_binary(id) -> {:ok, id, capability}
        _ -> {:error, {:invalid_thread_payload, result}}
      end
    end
  end

  defp await(port, id), do: Rpc.with_timeout_response(port, id, Config.agent_read_timeout_ms(), "", "Claude")
end
