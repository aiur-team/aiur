defmodule Aiur.Gemini.Transport do
  @moduledoc "Owned JSON-line ACP transport. Framing and process cleanup share the Muse port primitive."

  alias Aiur.Muse.Transport, as: JsonLines

  defdelegate start(workspace, command, opts), to: JsonLines
  defdelegate stop(port), to: JsonLines
  defdelegate metadata(port), to: JsonLines
  defdelegate send_frame(port, frame), to: JsonLines
  defdelegate decode_chunk(pending, chunk), to: JsonLines

  @spec request(port(), map(), pos_integer(), (map() -> term())) :: {:ok, map()} | {:error, term()}
  def request(port, frame, timeout, on_notification \\ fn _ -> :ok end) do
    case JsonLines.request(port, frame, timeout, on_notification) do
      {:error, {:msp_error, error}} -> {:error, {:acp_error, error}}
      {:error, :invalid_msp_response} -> {:error, :invalid_acp_response}
      {:error, :invalid_msp_frame} -> {:error, :invalid_acp_frame}
      result -> result
    end
  end
end
