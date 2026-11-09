defmodule Aiur.VoiceConversation.Receipts do
  @moduledoc "Reads Executor acknowledgements separately from voice session lifetime."

  alias Aiur.ExecutorWakeInbox

  @spec status([pos_integer()]) :: [map()]
  def status(event_ids) do
    case ExecutorWakeInbox.voice_receipts(event_ids) do
      {:ok, receipts} -> receipts
      {:error, _reason} -> unavailable(event_ids)
    end
  catch
    :exit, _reason -> unavailable(event_ids)
  end

  defp unavailable(event_ids), do: Enum.map(event_ids, &%{id: &1, ack_status: "unavailable"})
end
