defmodule AiurWeb.VoiceConverse.Frames do
  @moduledoc false
  alias VoiceConverse.Wire

  @max_audio 262_144
  @max_encoded 4 * div(@max_audio + 2, 3)

  @spec input(String.t(), term(), map()) :: :ok | {:ok, term()} | {:error, term()}
  def input(event, payload, assigns) when is_map(payload) do
    frame = payload |> Map.put("v", 1) |> Map.put("type", type(event)) |> audio_data(event)

    with {:ok, json} <- Wire.encode(frame),
         {:ok, frame} <- Wire.decode(json) do
      dispatch(frame, assigns)
    else
      _ -> {:error, :invalid_payload}
    end
  end

  def input(_, _, _), do: {:error, :invalid_payload}

  defp type("client_text"), do: "text"
  defp type(event), do: event
  defp audio_data(frame, "audio"), do: Map.put(frame, "data_b64", frame["data"] || frame["data_b64"])
  defp audio_data(frame, _), do: frame

  defp dispatch(%{"type" => "audio", "data_b64" => data}, a) do
    with :ok <- audio_valid(data), do: VoiceConverse.push_audio(a.instance, a.conversation_id, data)
  end

  defp dispatch(%{"type" => "text", "text" => text}, a), do: VoiceConverse.push_text(a.instance, a.conversation_id, text)
  defp dispatch(%{"type" => "end"}, a), do: VoiceConverse.end_session(a.instance, a.conversation_id, :user_end)

  defp dispatch(%{"type" => "confirm_draft", "draft_id" => id} = frame, a) when is_binary(id) and byte_size(id) in 1..256 do
    opts = [origin: :client] ++ if(Map.has_key?(frame, "edited_text"), do: [edited_text: frame["edited_text"]], else: [])
    VoiceConverse.confirm_draft(a.instance, a.conversation_id, id, opts)
  end

  defp dispatch(%{"type" => "discard_draft", "draft_id" => id}, a) when is_binary(id) and byte_size(id) in 1..256,
    do: VoiceConverse.discard_draft(a.instance, a.conversation_id, id, origin: :client)

  defp dispatch(%{"type" => "playback_state"} = frame, a),
    do: VoiceConverse.playback_state(a.instance, a.conversation_id, frame)

  defp dispatch(_, _), do: {:error, :invalid_payload}

  defp audio_valid(data) when is_binary(data) and byte_size(data) > @max_encoded, do: {:error, :chunk_too_large}

  defp audio_valid(data) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, pcm} when byte_size(pcm) > @max_audio -> {:error, :chunk_too_large}
      {:ok, pcm} when byte_size(pcm) > 0 and rem(byte_size(pcm), 2) == 0 -> :ok
      _ -> {:error, :invalid_payload}
    end
  end

  defp audio_valid(_), do: {:error, :invalid_payload}

  @spec push(Phoenix.Socket.t(), [map()]) :: :ok
  def push(socket, frames) do
    Enum.each(frames, fn frame ->
      {:ok, json} = Wire.encode(frame)
      {:ok, decoded} = Wire.decode(json)
      Phoenix.Channel.push(socket, event(decoded["type"]), payload(decoded))
    end)
  end

  defp event("agent_text"), do: "assistant_text"
  defp event("agent_audio"), do: "audio"
  defp event(type), do: type
  defp payload(%{"type" => "agent_audio", "data_b64" => data} = frame), do: Map.put(frame, "data", data)
  defp payload(%{"type" => "error", "code" => code} = frame), do: Map.put(frame, "reason_code", code)
  defp payload(frame), do: frame
end
