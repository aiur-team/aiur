defmodule Aiur.VoiceConversation.Handoff do
  @moduledoc "Durable session-end handoff; summary categories are untrusted agent-supplied context."

  alias Aiur.ExecutorEvents

  @topic "executor.voice.session_ended"

  @spec deliver(String.t(), [map()], term()) :: {:ok, map()} | {:error, term()}
  def deliver(session_id, transcript, reason), do: deliver(session_id, transcript, reason, nil)

  @spec deliver(String.t(), [map()], term(), map() | nil) :: {:ok, map()} | {:error, term()}
  def deliver(session_id, transcript, reason, summary) when is_binary(session_id) and is_list(transcript) do
    at = DateTime.utc_now() |> DateTime.to_iso8601()
    summary = summary_payload(summary)
    payload = %{session_id: session_id, transcript: transcript, summary: summary, reason: reason_text(reason), ended_at: at, untrusted_fields: ["transcript", "summary"]}

    with {:ok, id, _subscribers} <- ExecutorEvents.publish(@topic, payload, source: :internal) do
      {:ok, %{id: id, topic: @topic, at: at, status: "queued", summary_status: summary.status}}
    end
  end

  defp summary_payload(nil), do: %{status: "unstructured"}
  defp summary_payload(summary), do: Map.put(summary, :status, "structured")
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
