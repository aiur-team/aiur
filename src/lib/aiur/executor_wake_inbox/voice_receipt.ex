defmodule Aiur.ExecutorWakeInbox.VoiceReceipt do
  @moduledoc false

  alias Aiur.ExecutorWakeInbox.Storage

  @topic "executor.voice.session_ended"

  @spec read(map(), [pos_integer()]) :: {:ok, [map()], map()} | {:error, term()}
  def read(state, event_ids) do
    with {:ok, _unread, state} <- Storage.unread_records(state) do
      cursor = Storage.current_cursor(state)
      observed_at = DateTime.utc_now() |> DateTime.to_iso8601()
      receipts = Enum.map(event_ids, &receipt(state, &1, cursor, observed_at))
      {:ok, receipts, %{state | cursor: cursor}}
    end
  end

  defp receipt(state, event_id, cursor, observed_at) do
    durable = Enum.find(state.records, &matches?(&1, event_id))
    pending = Enum.find(Map.values(state.pending), &matches?(&1, event_id))
    record = durable || pending

    %{
      id: event_id,
      wake_id: record && record["wake_id"],
      ack_status: status(durable, pending, cursor),
      observed_at: observed_at
    }
  end

  defp matches?(record, event_id), do: record["topic"] == @topic and record["event_id"] == event_id
  defp status(%{"wake_id" => wake_id}, _pending, cursor) when wake_id <= cursor, do: "received"
  defp status(nil, nil, _cursor), do: "missing"
  defp status(_durable, _pending, _cursor), do: "waiting"
end
