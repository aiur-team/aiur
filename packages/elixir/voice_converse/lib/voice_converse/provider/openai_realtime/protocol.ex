defmodule VoiceConverse.Provider.OpenAIRealtime.Protocol do
  @moduledoc false
  alias VoiceConverse.Events

  @spec setup(map()) :: map()
  def setup(spec) do
    %{
      type: "session.update",
      session: %{
        type: "realtime",
        instructions: spec.system_prompt <> "\n\n" <> spec.context,
        output_modalities: ["audio"],
        audio: %{
          input: %{
            format: %{type: "audio/pcm", rate: 24_000},
            transcription: %{model: "gpt-4o-mini-transcribe"},
            turn_detection: %{type: "server_vad", create_response: true, interrupt_response: true}
          },
          output: %{format: %{type: "audio/pcm", rate: 24_000}, voice: Map.get(spec, :voice_id) || "marin"}
        },
        tools: Enum.map(spec.tools, &Map.put(&1, :type, "function")),
        tool_choice: "auto"
      }
    }
  end

  @spec message(String.t(), String.t()) :: map()
  def message(role, text) do
    %{
      type: "conversation.item.create",
      item: %{type: "message", role: role, content: [%{type: "input_text", text: text}]}
    }
  end

  @spec decode(map()) :: Events.t() | :ignore | :invalid
  def decode(%{"type" => "conversation.item.input_audio_transcription.completed", "transcript" => text})
      when is_binary(text),
      do: %Events.UserTranscript{text: text, final?: true}

  def decode(%{"type" => "response.output_audio_transcript.done", "item_id" => id, "transcript" => text})
      when is_binary(id) and is_binary(text),
      do: %Events.AgentText{turn_id: id, text: text, final?: true}

  def decode(%{"type" => "response.output_audio.delta", "item_id" => id, "delta" => data})
      when is_binary(id) and is_binary(data) do
    case Base.decode64(data) do
      {:ok, pcm} when rem(byte_size(pcm), 2) == 0 ->
        %Events.AgentAudio{turn_id: id, data_b64: data, format: :pcm_24000}

      _ ->
        :invalid
    end
  end

  def decode(%{"type" => "response.function_call_arguments.done", "call_id" => id, "name" => name, "arguments" => args})
      when is_binary(id) and is_binary(name) and is_binary(args) do
    case Jason.decode(args) do
      {:ok, params} when is_map(params) -> %Events.ToolCall{call_id: id, name: name, params: params}
      _ -> :invalid
    end
  end

  def decode(%{"type" => "error", "error" => error}) when is_map(error) do
    code = error_code(error["code"])
    Events.Error.new(code, "OpenAI Realtime request failed.")
  end

  def decode(%{"type" => "response.done", "response" => %{"status" => "failed"}}),
    do: Events.Error.new(:provider_error, "OpenAI Realtime response failed.")

  def decode(%{"type" => "conversation.item.input_audio_transcription.failed"}),
    do: Events.Error.new(:provider_error, "OpenAI Realtime transcription failed.")

  def decode(_), do: :ignore

  defp error_code(code) when code in ["invalid_api_key", "authentication_error"], do: :provider_auth
  defp error_code(code) when code in ["rate_limit_exceeded", "insufficient_quota"], do: :provider_quota
  defp error_code(_), do: :provider_error
end
