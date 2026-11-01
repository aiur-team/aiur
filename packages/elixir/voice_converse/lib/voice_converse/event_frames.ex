defmodule VoiceConverse.EventFrames do
  @moduledoc "Normalized session events encoded as transport-neutral wire frames."
  alias VoiceConverse.Events

  @spec frames(term()) :: [map()]
  def frames(%Events.UserTranscript{text: text, final?: final?}),
    do: [%{v: 1, type: "transcript", kind: if(final?, do: "final", else: "partial"), text: text}]

  def frames(%Events.AgentText{turn_id: id, text: text, final?: final?}),
    do: [%{v: 1, type: "agent_text", turn_id: to_string(id), text: text, final: final?}]

  def frames(%Events.AgentAudio{turn_id: id, format: format, data_b64: data}) do
    case Base.decode64(data) do
      {:ok, pcm} -> audio_frames(pcm, to_string(id), to_string(format))
      :error -> frames({:error, :provider_error, "Invalid provider audio."})
    end
  end

  def frames(%Events.Interruption{turn_id: id}), do: [%{v: 1, type: "interrupted", turn_id: to_string(id)}]
  def frames(%Events.Error{code: code, message: message}), do: frames({:error, code, message})
  def frames({:state, state}), do: [%{v: 1, type: "state", state: to_string(state)}]
  def frames({:draft, %{status: status} = record}) when status in ["proposed", "unknown"], do: [Map.put(record, :v, 1)]
  def frames({:draft, %{draft_id: id, status: status}}), do: [%{v: 1, type: "delivery", draft_id: id, status: status}]
  def frames({:error, code, message}), do: [%{v: 1, type: "error", code: to_string(code), message: message}]
  def frames({:ended, reason}), do: [%{v: 1, type: "ended", reason: to_string(reason)}]
  def frames(_), do: []

  defp audio_frames(<<chunk::binary-size(131_072), rest::binary>>, id, format),
    do: [audio(chunk, id, format) | audio_frames(rest, id, format)]

  defp audio_frames(<<>>, _id, _format), do: []
  defp audio_frames(chunk, id, format), do: [audio(chunk, id, format)]

  defp audio(chunk, id, format),
    do: %{v: 1, type: "agent_audio", turn_id: id, format: format, data_b64: Base.encode64(chunk)}
end
