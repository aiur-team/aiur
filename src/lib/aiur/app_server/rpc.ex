defmodule Aiur.AppServer.Rpc do
  @moduledoc """
  Shared JSON-line transport helpers for app-server backends.
  """

  require Logger

  @max_stream_log_bytes 1_000

  @spec send_line(port(), map()) :: true
  def send_line(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  @type notification_handler :: (map() -> :handled | :ignore)

  @spec with_timeout_response(port(), integer(), non_neg_integer(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def with_timeout_response(port, request_id, timeout_ms, pending_line, backend_label) do
    with_timeout_response(port, request_id, timeout_ms, pending_line, backend_label, fn _payload -> :ignore end)
  end

  @spec with_timeout_response(
          port(),
          integer(),
          non_neg_integer(),
          String.t(),
          String.t(),
          notification_handler()
        ) ::
          {:ok, map()} | {:error, term()}
  def with_timeout_response(port, request_id, timeout_ms, pending_line, backend_label, on_notification)
      when is_function(on_notification, 1) do
    with_timeout_response(port, request_id, timeout_ms, pending_line, backend_label, on_notification, false)
  end

  @spec with_timeout_response(
          port(),
          integer(),
          non_neg_integer(),
          String.t(),
          String.t(),
          notification_handler(),
          boolean()
        ) ::
          {:ok, map()} | {:error, term()}
  def with_timeout_response(port, request_id, timeout_ms, pending_line, backend_label, on_notification, sensitive_response?)
      when is_function(on_notification, 1) and is_boolean(sensitive_response?) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)

        handle_response(
          port,
          request_id,
          complete_line,
          timeout_ms,
          backend_label,
          on_notification,
          sensitive_response?
        )

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(
          port,
          request_id,
          timeout_ms,
          pending_line <> to_string(chunk),
          backend_label,
          on_notification,
          sensitive_response?
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  @spec handle_response(port(), integer(), binary(), non_neg_integer(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def handle_response(port, request_id, data, timeout_ms, backend_label) do
    handle_response(port, request_id, data, timeout_ms, backend_label, fn _payload -> :ignore end)
  end

  @spec handle_response(port(), integer(), binary(), non_neg_integer(), String.t(), notification_handler()) ::
          {:ok, map()} | {:error, term()}
  def handle_response(port, request_id, data, timeout_ms, backend_label, on_notification) when is_function(on_notification, 1) do
    handle_response(port, request_id, data, timeout_ms, backend_label, on_notification, false)
  end

  @spec handle_response(
          port(),
          integer(),
          binary(),
          non_neg_integer(),
          String.t(),
          notification_handler(),
          boolean()
        ) ::
          {:ok, map()} | {:error, term()}
  def handle_response(port, request_id, data, timeout_ms, backend_label, on_notification, sensitive_response?)
      when is_function(on_notification, 1) and is_boolean(sensitive_response?) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        maybe_route_notification(other, on_notification, backend_label)
        with_timeout_response(port, request_id, timeout_ms, "", backend_label, on_notification, sensitive_response?)

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream", backend_label, sensitive_response?: sensitive_response?)
        with_timeout_response(port, request_id, timeout_ms, "", backend_label, on_notification, sensitive_response?)
    end
  end

  defp maybe_route_notification(payload, on_notification, backend_label) do
    case on_notification.(payload) do
      :handled -> :ok
      :ignore -> Logger.debug("Ignoring #{describe_message(payload)} while waiting for #{backend_label} response")
      _ -> Logger.debug("Ignoring unrecognized notification handler result while waiting for #{backend_label} response")
    end
  rescue
    _ -> Logger.debug("Notification handler failed while waiting for #{backend_label} response")
  end

  defp describe_message(%{"method" => method}) when is_binary(method), do: "method #{inspect(method)}"
  defp describe_message(%{"id" => id}), do: "response id #{inspect(id)}"
  defp describe_message(_payload), do: "message"

  @spec log_non_json_stream_line(binary(), String.t(), String.t()) :: :ok | nil
  def log_non_json_stream_line(data, stream_label, backend_label), do: log_non_json_stream_line(data, stream_label, backend_label, [])

  @spec log_non_json_stream_line(binary(), String.t(), String.t(), keyword()) :: :ok | nil
  def log_non_json_stream_line(data, stream_label, backend_label, opts) do
    if Keyword.get(opts, :sensitive_response?, false) do
      Logger.warning("#{backend_label} sensitive #{stream_label} output redacted")
    else
      log_stream_line(data, stream_label, backend_label)
    end
  end

  defp log_stream_line(data, stream_label, backend_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("#{backend_label} #{stream_label} output: #{text}")
      else
        Logger.debug("#{backend_label} #{stream_label} output: #{text}")
      end
    end
  end
end
