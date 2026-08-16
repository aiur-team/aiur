defmodule AiurWeb.VoiceChannel do
  @moduledoc """
  Browser dictation channel: the second producer feeding the shared
  ElevenLabs transcription path.

  The browser captures audio with `getUserMedia` (it cannot run the Node
  sidecar's PipeWire capture), pushes raw PCM chunks here, and this channel
  owns a server-side `Aiur.ElevenLabs.Realtime` session. Transcript frames are
  streamed back to the browser so the composer shows live partial text and
  settles to finals. Dictation waits for the operator to press Send; the
  separate conversation topic uses the same normal send path after an explicit
  push-to-talk turn and can stream the next agent reply as PCM audio.

  The ElevenLabs API key never reaches the browser: it is resolved server-side
  and travels only inside the STT session's request header.
  """

  use Phoenix.Channel

  require Logger

  alias Aiur.ElevenLabs.{Realtime, TTS}
  alias AiurWeb.{Endpoint, FinancialDataAccess, VoiceSessionLimiter}

  # An audio chunk larger than this is rejected outright: at 16 kHz mono PCM16,
  # 256 KiB is roughly 8 seconds of audio, well past any single dictation push
  # the browser sends (chunks are ~100-200 ms). Rejecting before the base64
  # decode keeps a malicious client from making the server allocate.
  @max_audio_bytes 262_144
  @max_audio_base64_bytes 4 * div(@max_audio_bytes + 2, 3)
  @default_max_session_audio_bytes 9_600_000

  @impl true
  def join(
        topic,
        _payload,
        %{
          assigns: %{
            voice_authority: %{
              configuration_generation: generation,
              connection_generation: connection_generation
            }
          }
        } = socket
      )
      when topic in ["voice:dictation", "voice:conversation"] do
    :ok = FinancialDataAccess.subscribe_to_configuration_changes()

    with true <- Endpoint.config(:dashboard_writable) == true,
         {:ok, ^generation} <- FinancialDataAccess.current_configuration_generation(),
         {:ok, lease} <- VoiceSessionLimiter.acquire(connection_generation) do
      join_stt(socket, generation, lease, topic)
    else
      false -> {:error, %{reason: "Dashboard writing is disabled."}}
      {:error, :capacity} -> {:error, %{reason: "Too many dashboard dictation sessions are active. Close another microphone and retry."}}
      _stale_or_invalid -> {:error, %{reason: "Dashboard authentication changed. Reload and sign in again."}}
    end
  end

  def join("voice:dictation", _payload, _socket), do: {:error, %{reason: "unauthorized"}}

  def join(_topic, _payload, _socket), do: {:error, %{reason: "invalid_topic"}}

  defp join_stt(socket, generation, lease, topic) do
    case start_stt(socket) do
      {:ok, %{pid: pid}} ->
        {:ok,
         socket
         |> assign(:stt, %{pid: pid})
         |> assign(:voice_mode, if(topic == "voice:conversation", do: :conversation, else: :dictation))
         |> assign(:voice_tts, nil)
         |> assign(:voice_tts_spoken?, false)
         |> assign(:voice_generation, generation)
         |> assign(:voice_audio_bytes, 0)
         |> assign(:voice_lease, lease)}

      {:error, reason} ->
        :ok = VoiceSessionLimiter.release(lease)
        {:error, %{reason: reason}}
    end
  end

  @impl true
  def handle_in("audio", %{"data" => data}, socket) when is_binary(data) do
    case decode_audio(data) do
      {:ok, pcm} ->
        audio_bytes = socket.assigns.voice_audio_bytes + byte_size(pcm)

        if audio_bytes <= max_session_audio_bytes() do
          Realtime.push(socket.assigns.stt.pid, data)
          {:noreply, assign(socket, :voice_audio_bytes, audio_bytes)}
        else
          push(socket, "error", %{"reason" => "Dictation reached the five-minute limit. Review the text and start again."})
          {:stop, :normal, socket}
        end

      {:error, reason} ->
        push(socket, "error", %{"reason" => reason})
        {:noreply, socket}
    end
  end

  def handle_in("audio", _payload, socket) do
    push(socket, "error", %{"reason" => "Audio chunk encoding is invalid."})
    {:noreply, socket}
  end

  @impl true
  def handle_in("stop", _payload, socket) do
    case socket.assigns.stt do
      %{pid: pid} -> Realtime.commit(pid)
      nil -> push(socket, "stopped", %{"text" => ""})
    end

    {:noreply, socket}
  end

  def handle_in(
        "speak",
        %{"text" => text},
        %{
          assigns: %{
            voice_mode: :conversation,
            stt: nil,
            voice_lease: nil,
            voice_tts: nil,
            voice_tts_spoken?: false
          }
        } = socket
      )
      when is_binary(text) do
    case start_bounded_tts(socket, text) do
      {:ok, pid, lease} ->
        {:noreply,
         socket
         |> assign(:voice_tts, pid)
         |> assign(:voice_tts_spoken?, true)
         |> assign(:voice_lease, lease)}

      {:error, reason} ->
        push(socket, "audio_error", %{"reason" => tts_error(reason)})
        {:noreply, socket}
    end
  end

  def handle_in("speak", _payload, %{assigns: %{voice_mode: :conversation}} = socket) do
    push(socket, "audio_error", %{"reason" => "A voice reply was already requested for this turn."})
    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:elevenlabs_transcript, kind, text}, socket) when kind in [:partial, :final] and is_binary(text) do
    push(socket, "transcript", %{"kind" => Atom.to_string(kind), "text" => text})
    {:noreply, socket}
  end

  def handle_info({:elevenlabs_error, reason}, socket) when is_binary(reason) do
    push(socket, "error", %{"reason" => reason})
    {:noreply, socket}
  end

  def handle_info({:elevenlabs_closed}, socket) do
    push(socket, "stopped", %{})
    {:noreply, release_stt(socket)}
  end

  def handle_info({:elevenlabs_audio, :chunk, data}, socket) when is_binary(data) do
    push(socket, "audio", %{"data" => Base.encode64(data), "format" => "pcm_44100"})
    {:noreply, socket}
  end

  def handle_info({:elevenlabs_audio, :done}, socket) do
    push(socket, "audio_done", %{})
    {:noreply, socket |> assign(:voice_tts, nil) |> release_voice_lease()}
  end

  def handle_info({:elevenlabs_audio, :error, reason}, socket) when is_binary(reason) do
    push(socket, "audio_error", %{"reason" => reason})
    {:noreply, socket |> assign(:voice_tts, nil) |> release_voice_lease()}
  end

  def handle_info(
        {FinancialDataAccess, :configuration_changed, generation},
        %{assigns: %{voice_generation: generation}} = socket
      ),
      do: {:noreply, socket}

  def handle_info({FinancialDataAccess, :configuration_changed, _generation}, socket),
    do: {:stop, :normal, socket}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    case socket.assigns[:stt] do
      %{pid: pid} when is_pid(pid) ->
        Realtime.stop(pid)

      _ ->
        :ok
    end

    case socket.assigns[:voice_tts] do
      pid when is_pid(pid) -> Process.exit(pid, :shutdown)
      _missing -> :ok
    end

    case socket.assigns[:voice_lease] do
      lease when is_reference(lease) -> VoiceSessionLimiter.release(lease)
      _missing -> :ok
    end

    :ok
  end

  defp release_stt(socket) do
    socket
    |> assign(:stt, nil)
    |> release_voice_lease()
  end

  defp release_voice_lease(socket) do
    case socket.assigns[:voice_lease] do
      lease when is_reference(lease) -> :ok = VoiceSessionLimiter.release(lease)
      _missing -> :ok
    end

    assign(socket, :voice_lease, nil)
  end

  # --- helpers -------------------------------------------------------------

  # The STT session is injected through the endpoint config so channel tests
  # drive a fake transcriber; production uses the same
  # `Aiur.ElevenLabs.Realtime` session as Stream Deck voice input.
  defp start_stt(socket) do
    case Endpoint.config(:voice_stt_start_fun) do
      fun when is_function(fun, 1) ->
        safe_start(fun, socket)

      _ ->
        start_realtime()
    end
  end

  defp start_realtime do
    case Realtime.start(owner: self()) do
      {:ok, pid} ->
        {:ok, %{pid: pid}}

      {:error, :unconfigured} ->
        {:error, "ElevenLabs speech-to-text is not configured. Dictation is unavailable; ask the Executor to run `aiur init` and add an ElevenLabs API key."}

      {:error, reason} ->
        Logger.warning("voice dictation: ElevenLabs realtime session failed to start: #{inspect(reason)}")
        {:error, "Speech-to-text could not start. Check the daemon log and retry."}
    end
  rescue
    error ->
      Logger.warning("voice dictation: ElevenLabs STT setup failed: #{inspect(error)}")
      {:error, "Speech-to-text is unavailable right now."}
  catch
    _kind, _reason ->
      {:error, "Speech-to-text is unavailable right now."}
  end

  defp safe_start(fun, socket) do
    case fun.(socket) do
      {:ok, %{pid: pid}} when is_pid(pid) ->
        {:ok, %{pid: pid}}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, "Speech-to-text could not start."}
    end
  catch
    _kind, _reason -> {:error, "Speech-to-text could not start."}
  end

  defp start_tts(socket, text) do
    case Endpoint.config(:voice_tts_start_fun) do
      fun when is_function(fun, 2) -> fun.(socket, text)
      _ -> TTS.start(self(), text)
    end
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp start_bounded_tts(socket, text) do
    authority = socket.assigns.voice_authority.connection_generation

    with {:ok, lease} <- VoiceSessionLimiter.acquire(authority) do
      case start_tts(socket, text) do
        {:ok, pid} ->
          {:ok, pid, lease}

        {:error, _reason} = error ->
          :ok = VoiceSessionLimiter.release(lease)
          error
      end
    end
  end

  defp tts_error(:unconfigured),
    do: "ElevenLabs text-to-speech is not configured. Add elevenlabs.voice_id and grant the key Text to Speech permission."

  defp tts_error(:empty_text), do: "There is no agent reply to speak."
  defp tts_error(:text_too_large), do: "This agent reply is too long to speak."
  defp tts_error(:capacity), do: "Too many dashboard voice replies are active. Try again shortly."
  defp tts_error(_reason), do: "Voice playback could not start."

  defp decode_audio(data) do
    if byte_size(data) > @max_audio_base64_bytes do
      {:error, "Audio chunk is too large."}
    else
      case Base.decode64(data) do
        {:ok, pcm} when byte_size(pcm) <= @max_audio_bytes -> {:ok, pcm}
        {:ok, _pcm} -> {:error, "Audio chunk is too large."}
        :error -> {:error, "Audio chunk encoding is invalid."}
      end
    end
  end

  defp max_session_audio_bytes do
    Endpoint.config(:voice_max_session_audio_bytes) || @default_max_session_audio_bytes
  end
end
