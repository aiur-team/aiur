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

    into = fn {:data, data}, {request, response} ->
      bytes = Process.get(:aiur_tts_audio_bytes, 0) + byte_size(data)
      limited? = bytes > limits.max_audio_bytes or monotonic_ms() >= limits.deadline

      cond do
        limited? ->
          Process.put(:aiur_tts_limited, true)
          {:halt, {request, response}}

        not Process.alive?(owner) ->
          {:halt, {request, response}}

        true ->
          Process.put(:aiur_tts_audio_bytes, bytes)
          if response.status == 200, do: send(owner, {:elevenlabs_audio, :chunk, data})
          {:cont, {request, response}}
      end
    end

    url = "#{@endpoint}/#{URI.encode(voice_id, &URI.char_unreserved?/1)}/stream"

    options = [
      params: [output_format: @output_format],
      headers: [{"xi-api-key", api_key}],
      json: %{text: text, model_id: @model},
      into: into,
      raw: true,
      retry: false,
      receive_timeout: 60_000
    ]

    case request_fun.(url, options) do
      {:ok, %{status: 200}} ->
        if Process.get(:aiur_tts_limited) == true do
          notify(owner, {:elevenlabs_audio, :error, "Voice reply exceeded its playback limit"})
        else
          notify(owner, {:elevenlabs_audio, :done})
        end

      {:ok, _response} ->
        notify(owner, {:elevenlabs_audio, :error, "ElevenLabs could not speak this reply"})

      {:error, _opaque} ->
        notify(owner, {:elevenlabs_audio, :error, "Voice playback connection failed"})
    end
  rescue
    _error -> notify(owner, {:elevenlabs_audio, :error, "Voice playback failed"})
  catch
    _kind, _reason -> notify(owner, {:elevenlabs_audio, :error, "Voice playback failed"})
  end

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
