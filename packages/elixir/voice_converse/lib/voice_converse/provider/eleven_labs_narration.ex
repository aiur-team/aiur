defmodule VoiceConverse.Provider.ElevenLabsNarration do
  @moduledoc false

  alias VoiceConverse.Events
  alias VoiceConverse.Provider.ElevenLabsAgents.HTTP

  @speech_endpoint "https://api.elevenlabs.io/v1/text-to-speech"

  @spec render_speech(VoiceConverse.Provider.render_spec()) ::
          {:ok, VoiceConverse.Provider.render_result()} | {:error, Events.Error.t()}
  def render_speech(%{text: text, credentials: {credentials, provider_id}, format: format} = spec)
      when is_binary(text) and is_atom(credentials) and is_atom(provider_id) do
    with {:ok, key} <- fetch_render_key(credentials, provider_id),
         {:ok, status, body} <- http_post(Map.get(spec, :http, HTTP), speech_url(spec), render_request(spec, key)),
         {:ok, result} <- render_response(status, body, format) do
      {:ok, result}
    else
      {:error, %Events.Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Events.Error.new(:provider_unavailable, "ElevenLabs connection is unavailable.")}
    end
  rescue
    _error -> {:error, Events.Error.new(:provider_error, "ElevenLabs returned an invalid response.")}
  catch
    _kind, _reason -> {:error, Events.Error.new(:provider_unavailable, "ElevenLabs connection is unavailable.")}
  end

  def render_speech(_spec),
    do: {:error, Events.Error.new(:provider_error, "Invalid ElevenLabs narration specification.")}

  defp speech_url(spec) do
    base_url = Map.get(spec, :base_url, @speech_endpoint) |> String.trim_trailing("/")
    voice_id = Map.get(spec, :voice_id)
    model_id = Map.get(spec, :model_id, "eleven_multilingual_v2")
    base_url = if voice_id, do: base_url <> "/#{URI.encode(voice_id)}", else: base_url

    base_url <>
      "/with-timestamps?" <> URI.encode_query(%{"output_format" => format_query(spec.format), "model_id" => model_id})
  end

  defp render_request(spec, key) do
    %{
      headers: [{"xi-api-key", key}, {"content-type", "application/json"}, {"accept", "application/json"}],
      body: Jason.encode!(%{text: spec.text})
    }
  end

  defp http_post(http, url, opts) when is_function(http, 3), do: http.(url, opts[:headers], opts[:body])
  defp http_post(http, url, opts) when is_function(http, 2), do: http.(url, opts)
  defp http_post(http, url, opts), do: http.post(url, opts)

  defp format_query(:pcm_16000), do: "pcm_16000"
  defp format_query(:pcm_24000), do: "pcm_24000"
  defp format_query(:pcm_44100), do: "pcm_44100"
  defp format_query(_), do: "pcm_24000"

  defp render_response(200, body, format) do
    with {:ok, %{"audio_base64" => encoded, "alignment" => alignment}} <- Jason.decode(body),
         {:ok, audio} when rem(byte_size(audio), 2) == 0 <- Base.decode64(encoded),
         {:ok, segments} <- displayed_alignment(alignment),
         true <- ordered_alignment?(segments) do
      {:ok, %{audio: audio, format: format, alignment: segments}}
    else
      _ -> {:error, Events.Error.new(:provider_error, "ElevenLabs returned an invalid response.")}
    end
  end

  defp render_response(status, _body, _format) do
    code = http_error_code(status)
    {:error, Events.Error.new(code, error_message(code))}
  end

  defp displayed_alignment(%{
         "characters" => chars,
         "character_start_times_seconds" => starts,
         "character_end_times_seconds" => ends
       })
       when is_list(chars) and is_list(starts) and is_list(ends) and length(chars) == length(starts) and
              length(starts) == length(ends) do
    segments =
      Enum.zip([chars, starts, ends])
      |> Enum.reduce([], fn {char, start_s, end_s}, acc ->
        cond do
          not is_binary(char) or not is_number(start_s) or not is_number(end_s) -> acc ++ [:invalid]
          String.trim(char) == "" -> acc
          true -> acc ++ [%{text: char, start_ms: round(start_s * 1000), end_ms: round(end_s * 1000)}]
        end
      end)

    if :invalid in segments, do: {:error, :malformed_alignment}, else: {:ok, segments}
  end

  defp displayed_alignment(_), do: {:error, :malformed_alignment}

  defp ordered_alignment?(segments) do
    Enum.all?(segments, fn %{start_ms: start_ms, end_ms: end_ms} -> start_ms >= 0 and end_ms >= start_ms end) and
      segments |> Enum.map(& &1.start_ms) |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a <= b end)
  end

  defp fetch_render_key(credentials, provider_id) do
    case credentials.fetch(provider_id, :render) do
      {:ok, key} when is_binary(key) and byte_size(key) > 0 -> {:ok, key}
      _ -> {:error, Events.Error.new(:provider_auth, "no credential for #{provider_id}")}
    end
  rescue
    _ -> {:error, Events.Error.new(:provider_auth, "no credential for #{provider_id}")}
  catch
    _, _ -> {:error, Events.Error.new(:provider_auth, "no credential for #{provider_id}")}
  end

  defp http_error_code(status) when status in [401, 403], do: :provider_auth
  defp http_error_code(429), do: :provider_quota
  defp http_error_code(status) when status >= 500, do: :provider_unavailable
  defp http_error_code(_status), do: :provider_error

  defp error_message(:provider_auth), do: "ElevenLabs authentication failed."
  defp error_message(:provider_quota), do: "ElevenLabs quota is unavailable."
  defp error_message(:provider_error), do: "ElevenLabs returned an invalid response."
  defp error_message(:provider_unavailable), do: "ElevenLabs connection is unavailable."
end
