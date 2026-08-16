defmodule Aiur.ElevenLabs.TTS do
  @moduledoc """
  Streams one agent reply from ElevenLabs to a dashboard voice channel.

  The API key remains inside Aiur and is sent only in the provider request
  header. Callers receive raw 44.1 kHz mono PCM chunks, never the credential or
  provider response object.
  """

  alias Aiur.Config

  @endpoint "https://api.elevenlabs.io/v1/text-to-speech"
  @model "eleven_flash_v2_5"
  @output_format "pcm_44100"
  @max_text_bytes 16_000
  @max_audio_bytes 8_000_000
  @max_duration_ms 60_000

  @type request_fun :: (String.t(), keyword() -> {:ok, Req.Response.t()} | {:error, term()})

  @spec start(pid(), String.t(), keyword()) :: {:ok, pid()} | {:error, atom()}
  def start(owner, text, opts \\ []) when is_pid(owner) and is_binary(text) do
    with {:ok, text} <- validate_text(text),
         {:ok, api_key} <- configured(Keyword.get(opts, :api_key_fun, &Config.elevenlabs_api_key/0)),
         {:ok, voice_id} <- configured(Keyword.get(opts, :voice_id_fun, &Config.elevenlabs_voice_id/0)) do
      request_fun = Keyword.get(opts, :request_fun, &Req.post/2)

      limits = %{
        max_audio_bytes: Keyword.get(opts, :max_audio_bytes, @max_audio_bytes),
        deadline: monotonic_ms() + Keyword.get(opts, :max_duration_ms, @max_duration_ms)
      }

      Task.start(fn -> synthesize(owner, text, api_key, voice_id, request_fun, limits) end)
    end
  end

  defp synthesize(owner, text, api_key, voice_id, request_fun, limits) do
    Process.put(:aiur_tts_audio_bytes, 0)
    Process.put(:aiur_tts_limited, false)

    url = "#{@endpoint}/#{URI.encode(voice_id, &URI.char_unreserved?/1)}/stream"

    options = [
      params: [output_format: @output_format],
      headers: [{"xi-api-key", api_key}],
      json: %{text: text, model_id: @model},
      into: stream_into(owner, limits),
      raw: true,
      retry: false,
      receive_timeout: 60_000
    ]

    request_fun.(url, options)
    |> handle_result(owner)
  rescue
    _error -> notify(owner, {:elevenlabs_audio, :error, "Voice playback failed"})
  catch
    _kind, _reason -> notify(owner, {:elevenlabs_audio, :error, "Voice playback failed"})
  end

  defp stream_into(owner, limits) do
    fn {:data, data}, accumulator ->
      bytes = Process.get(:aiur_tts_audio_bytes, 0) + byte_size(data)

      stream_chunk(owner, data, bytes, limits, accumulator)
    end
  end

  defp stream_chunk(owner, data, bytes, limits, {request, response} = accumulator) do
    cond do
      bytes > limits.max_audio_bytes or monotonic_ms() >= limits.deadline ->
        Process.put(:aiur_tts_limited, true)
        {:halt, accumulator}

      not Process.alive?(owner) ->
        {:halt, accumulator}

      true ->
        Process.put(:aiur_tts_audio_bytes, bytes)
        forward_chunk(owner, response.status, data)
        {:cont, {request, response}}
    end
  end

  defp forward_chunk(owner, 200, data), do: send(owner, {:elevenlabs_audio, :chunk, data})
  defp forward_chunk(_owner, _status, _data), do: :ok

  defp handle_result({:ok, %{status: 200}}, owner) do
    if Process.get(:aiur_tts_limited) == true do
      notify(owner, {:elevenlabs_audio, :error, "Voice reply exceeded its playback limit"})
    else
      notify(owner, {:elevenlabs_audio, :done})
    end
  end

  defp handle_result({:ok, _response}, owner),
    do: notify(owner, {:elevenlabs_audio, :error, "ElevenLabs could not speak this reply"})

  defp handle_result({:error, _opaque}, owner),
    do: notify(owner, {:elevenlabs_audio, :error, "Voice playback connection failed"})

  defp validate_text(text) do
    text = String.trim(text)

    cond do
      text == "" -> {:error, :empty_text}
      byte_size(text) > @max_text_bytes -> {:error, :text_too_large}
      true -> {:ok, text}
    end
  end

  defp configured(reader) do
    case reader.() do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :unconfigured}
          configured -> {:ok, configured}
        end

      _absent ->
        {:error, :unconfigured}
    end
  rescue
    _unavailable -> {:error, :unconfigured}
  catch
    _kind, _reason -> {:error, :unconfigured}
  end

  defp notify(owner, message) do
    if Process.alive?(owner), do: send(owner, message)
    :ok
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
