defmodule Aiur.AppServer.Rpc.Stream do
  @moduledoc false

  require Logger

  @max_log_bytes 1_000

  @spec log_non_json(binary(), String.t(), String.t(), keyword()) :: :ok | nil
  def log_non_json(data, stream_label, backend_label, opts \\ []) do
    if Keyword.get(opts, :sensitive_response?, false) do
      Logger.warning("#{backend_label} sensitive #{stream_label} output redacted")
    else
      log_stream_line(data, stream_label, backend_label)
    end
  end

  defp log_stream_line(data, stream_label, backend_label) do
    text = data |> to_string() |> String.trim() |> String.slice(0, @max_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("#{backend_label} #{stream_label} output: #{text}")
      else
        Logger.debug("#{backend_label} #{stream_label} output: #{text}")
      end
    end
  end
end
