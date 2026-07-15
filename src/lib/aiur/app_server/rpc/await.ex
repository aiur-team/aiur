defmodule Aiur.AppServer.Rpc.Await do
  @moduledoc false

  alias Aiur.AppServer.Rpc

  @spec response(port(), integer(), non_neg_integer(), String.t(), String.t(), Rpc.notification_handler(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def response(port, request_id, timeout_ms, pending_line, backend_label, on_notification, sensitive_response?) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        handle_eol(port, request_id, timeout_ms, pending_line <> to_string(chunk), backend_label, on_notification, sensitive_response?)

      {^port, {:data, {:noeol, chunk}}} ->
        response(port, request_id, timeout_ms, pending_line <> to_string(chunk), backend_label, on_notification, sensitive_response?)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        retain_timeout(port, request_id, pending_line, sensitive_response?)
    end
  end

  defp handle_eol(port, request_id, timeout_ms, complete_line, backend_label, on_notification, sensitive_response?) do
    if Rpc.discard_late_sensitive_response?(port, complete_line) do
      log_discarded_sensitive_response(complete_line, backend_label)
      response(port, request_id, timeout_ms, "", backend_label, on_notification, sensitive_response?)
    else
      Rpc.handle_response(port, request_id, complete_line, timeout_ms, backend_label, on_notification, sensitive_response?)
    end
  end

  defp retain_timeout(port, request_id, pending_line, true) do
    Rpc.retain_late_sensitive_response(port, request_id, pending_line != "")
    {:error, :response_timeout}
  end

  defp retain_timeout(_port, _request_id, _pending_line, false), do: {:error, :response_timeout}

  defp log_discarded_sensitive_response(data, backend_label) do
    case Jason.decode(data) do
      {:ok, _payload} -> :ok
      {:error, _reason} -> Rpc.log_non_json_stream_line(data, "response stream", backend_label, sensitive_response?: true)
    end
  end
end
