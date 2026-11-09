defmodule VoiceConverse.Provider.ElevenLabsAgents.Decoder do
  @moduledoc "Pure mapping of documented ElevenLabs websocket frames to conversation events."

  alias VoiceConverse.Events

  @known ~w(user_transcript agent_response agent_response_correction audio interruption client_tool_call)

  @spec decode(term(), map()) :: {:ok, Events.t()} | {:ignore, String.t()} | {:error, :malformed_event}
  def decode(frame, context \\ %{})

  def decode(text, context) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, frame} -> decode(frame, context)
      {:error, _reason} -> {:error, :malformed_event}
    end
  end

  def decode(%{"type" => "user_transcript", "user_transcription_event" => %{"user_transcript" => text}}, _)
      when is_binary(text),
      do: {:ok, %Events.UserTranscript{text: text, final?: false}}

  def decode(%{"type" => "agent_response", "agent_response_event" => %{"agent_response" => text} = event}, _)
      when is_binary(text),
      do: {:ok, %Events.AgentText{turn_id: turn_id(event), text: text, final?: true}}

  def decode(
        %{
          "type" => "agent_response_correction",
          "agent_response_correction_event" => %{"corrected_agent_response" => text} = event
        },
        _
      )
      when is_binary(text),
      do: {:ok, %Events.AgentText{turn_id: turn_id(event), text: text, final?: true}}

  def decode(%{"type" => "audio", "audio_event" => %{"audio_base_64" => data} = event}, context)
      when is_binary(data) do
    {:ok,
     %Events.AgentAudio{
       turn_id: turn_id(event) || Map.get(context, :turn_id),
       format: Map.get(context, :audio_out, :pcm_16000),
       data_b64: data
     }}
  end

  def decode(%{"type" => "interruption", "interruption_event" => event}, context) when is_map(event),
    do: {:ok, %Events.Interruption{turn_id: Map.get(context, :turn_id) || turn_id(event)}}

  def decode(
        %{
          "type" => "client_tool_call",
          "client_tool_call" => %{"tool_call_id" => id, "tool_name" => name, "parameters" => params}
        },
        _
      )
      when is_binary(id) and is_binary(name) and is_map(params),
      do: {:ok, %Events.ToolCall{call_id: id, name: name, params: params}}

  def decode(%{"type" => type}, _) when is_binary(type) and type not in @known, do: {:ignore, type}
  def decode(_, _), do: {:error, :malformed_event}

  @spec tool_result(String.t(), %{text: String.t(), is_error: boolean()}) :: map()
  def tool_result(call_id, %{text: text, is_error: is_error}) when is_binary(text) and is_boolean(is_error) do
    %{type: "client_tool_result", tool_call_id: call_id, result: text, is_error: is_error}
  end

  defp turn_id(event), do: event["response_id"] || event["event_id"]
end
