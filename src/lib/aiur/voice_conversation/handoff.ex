defmodule Aiur.VoiceConversation.Handoff do
  @moduledoc "Durable session-end handoff to the Executor; a receipt confirms queueing only."

  alias Aiur.ExecutorEvents

  @topic "executor.voice.session_ended"

  @spec deliver(String.t(), [map()], term()) :: {:ok, map()} | {:error, term()}
  def deliver(session_id, transcript, reason) when is_binary(session_id) and is_list(transcript) do
    at = DateTime.utc_now() |> DateTime.to_iso8601()

    payload = %{
      session_id: session_id,
      transcript: transcript,
      summary: summary(transcript),
      reason: reason_text(reason),
      ended_at: at,
      untrusted_fields: ["transcript", "summary"]
    }

    with {:ok, id, _subscribers} <- ExecutorEvents.publish(@topic, payload, source: :internal) do
      {:ok, %{id: id, topic: @topic, at: at, status: "queued"}}
    end
  end

  defp summary(transcript) do
    preview =
      transcript
      |> Enum.take(3)
      |> Enum.map_join("; ", fn turn -> "#{field(turn, :role)}: #{field(turn, :text)}" end)
      |> String.slice(0, 450)

    "#{length(transcript)} transcript turns" <> if(preview == "", do: ".", else: ": " <> preview)
  end

  defp field(turn, key) when is_map(turn), do: Map.get(turn, key, Map.get(turn, Atom.to_string(key), ""))
  defp field(_turn, _key), do: ""

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
