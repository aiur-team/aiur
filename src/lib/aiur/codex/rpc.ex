defmodule Aiur.Codex.Rpc do
  @moduledoc """
  Codex-specific startup RPC helpers layered over the shared app-server RPC.
  """

  alias Aiur.AppServer.Rpc, as: AppServerRpc
  alias Aiur.Config

  @cold_start_response_timeout_ms 30_000

  @spec send_message(port(), map()) :: true
  def send_message(port, message), do: AppServerRpc.send_line(port, message)

  @spec await_startup_response(port(), integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def await_startup_response(port, request_id, opts \\ []) do
    await_response(port, request_id, startup_response_timeout_ms(), opts)
  end

  @spec await_response(port(), integer(), non_neg_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def await_response(port, request_id, timeout_ms, opts \\ []) do
    on_notification = Keyword.get(opts, :on_notification, fn _payload -> :ignore end)
    sensitive_response? = Keyword.get(opts, :sensitive_response?, false)
    AppServerRpc.with_timeout_response(port, request_id, timeout_ms, "", "Codex", on_notification, sensitive_response?)
  end

  @spec startup_response_timeout_ms(non_neg_integer()) :: non_neg_integer()
  def startup_response_timeout_ms(read_timeout_ms \\ Config.agent_read_timeout_ms()) do
    max(read_timeout_ms, @cold_start_response_timeout_ms)
  end
end
