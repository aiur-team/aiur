defmodule Aiur.ElevenLabs.STT.Protocol do
  @moduledoc """
  Pure encoding and classification for ElevenLabs realtime STT frames.

  Keeping provider vocabulary out of the session process makes readiness,
  buffering, and process cleanup independently reviewable.
  """

  @realtime_path "/v1/speech-to-text/realtime"
  @realtime_model "scribe_v2_realtime"

  @final_types ["committed_transcript", "committed_transcript_with_timestamps"]
  @partial_types ["partial_transcript", "final_transcript", "final_transcript_with_timestamps"]
  @error_types [
    "error",
    "auth_error",
    "quota_exceeded",
    "commit_throttled",
    "unaccepted_terms",
    "rate_limited",
    "queue_overflow",
    "resource_exhausted",
    "session_time_limit_exceeded",
    "input_error",
    "invalid_request",
    "chunk_size_exceeded",
    "insufficient_audio_activity",
    "transcriber_error"
  ]

  @type provider_event ::
          :session_started
          | {:transcript, :partial | :final, String.t()}
          | {:error, String.t()}
          | :ignore

  @spec path(String.t(), pos_integer(), String.t()) :: String.t()
  def path(base_url, sample_rate, language_code) do
    uri = URI.parse(base_url)
    path = uri.path || @realtime_path

    query =
      URI.encode_query(
        model_id: @realtime_model,
        audio_format: "pcm_#{sample_rate}",
        language_code: language_code,
        commit_strategy: "vad"
      )

    path <> "?" <> query
  end

  @spec audio_frame(String.t(), pos_integer(), boolean()) :: String.t()
  def audio_frame(audio_base64, sample_rate, commit?) do
    Jason.encode!(%{
      message_type: "input_audio_chunk",
      audio_base_64: audio_base64,
      commit: commit?,
      sample_rate: sample_rate
    })
  end

  @spec decode(binary()) :: provider_event()
  def decode(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"message_type" => "session_started"}} ->
        :session_started

      {:ok, %{"message_type" => type, "text" => text}}
      when type in @final_types and is_binary(text) ->
        {:transcript, :final, text}

      {:ok, %{"message_type" => type, "text" => text}}
      when type in @partial_types and is_binary(text) ->
        {:transcript, :partial, text}

      {:ok, %{"message_type" => type}} when type in @error_types ->
        {:error, describe_failure(type)}

      _other ->
        :ignore
    end
  rescue
    _error -> :ignore
  catch
    _kind, _reason -> :ignore
  end

  def decode(_data), do: :ignore

  defp describe_failure("auth_error"), do: "ElevenLabs rejected the API key"
  defp describe_failure("quota_exceeded"), do: "ElevenLabs quota exhausted"
  defp describe_failure(type) when type in ["rate_limited", "commit_throttled"], do: "ElevenLabs rate limit reached"
  defp describe_failure("unaccepted_terms"), do: "ElevenLabs terms not accepted for this account"
  defp describe_failure("session_time_limit_exceeded"), do: "ElevenLabs session time limit reached"
  defp describe_failure(_type), do: "Speech-to-text failed"
end
