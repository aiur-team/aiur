defmodule AiurWeb.VoiceChannel do
  @moduledoc """
  Browser dictation channel: the second producer feeding the shared
  provider-neutral transcription path.

  The browser captures audio with `getUserMedia` (it cannot run the Node
  sidecar's PipeWire capture), pushes raw PCM chunks here, and this channel
  owns a server-side `Aiur.Voice` session. Transcript frames are
  streamed back to the browser so the composer shows live partial text and
  settles to finals. Dictation waits for the operator to press Send; the
  separate conversation topic uses the same normal send path after an explicit
  push-to-talk turn and can stream the next agent reply as PCM audio.

  The ElevenLabs API key never reaches the browser: it is resolved server-side
  and travels only inside the STT session's request header.
  """

  use Phoenix.Channel

  require Logger

  alias Aiur.Voice
  alias AiurWeb.{EndpointConfig, FinancialDataAccess, VoiceJoinPayload, VoiceReasonCode, VoiceSessionLimiter, VoiceTargets}

  # An audio chunk larger than this is rejected outright: at 16 kHz mono PCM16,
  # 256 KiB is roughly 8 seconds of audio, well past any single dictation push
  # the browser sends (chunks are ~100-200 ms). Rejecting before the base64
  # decode keeps a malicious client from making the server allocate.
  @max_audio_bytes 262_144
  @max_audio_base64_bytes 4 * div(@max_audio_bytes + 2, 3)
  @default_max_session_audio_bytes 9_600_000
  @voice_not_installed_reason "Voice input isn't installed in this Aiur. Typed messages work as usual."
  # `voice:dictation` is the alias old browsers join until every client uses
  # `voice:dictate`.
  @dictate_topics ["voice:dictate", "voice:dictation"]

  @impl true
  def join(
        topic,
        payload,
        %{
          assigns: %{
            voice_authority: %{
              configuration_generation: generation,
              connection_generation: connection_generation
            }
          }
        } = socket
      )
      when topic in ["voice:conversation" | @dictate_topics] do
    :ok = FinancialDataAccess.subscribe_to_configuration_changes()

    with true <- EndpointConfig.get(:dashboard_writable) == true,
         {:ok, ^generation} <- FinancialDataAccess.current_configuration_generation(),
         {:ok, lease} <- VoiceSessionLimiter.acquire(connection_generation) do
      join_target(socket, generation, lease, topic, payload)
    else
      false -> refuse("Dashboard writing is disabled.", "read_only")
      {:error, :capacity} -> refuse("Too many dashboard dictation sessions are active. Close another microphone and retry.", "capacity")
      _stale_or_invalid -> refuse("Dashboard authentication changed. Reload and sign in again.", "auth_changed")
    end
  end

  def join(topic, _payload, _socket) when topic in @dictate_topics, do: refuse("unauthorized", "auth_changed")

  def join(_topic, _payload, _socket), do: refuse("invalid_topic", "invalid_payload")

  # The lease is already held: every refusal past this point releases it.
  defp join_target(socket, generation, lease, "voice:conversation", _payload),
    do: join_stt(socket, generation, lease, "voice:conversation", nil)

  defp join_target(socket, generation, lease, topic, payload) do
    case dictate_target(payload) do
      {:ok, target} ->
        join_stt(socket, generation, lease, topic, target)

      {:error, refusal} ->
        :ok = VoiceSessionLimiter.release(lease)
        {:error, refusal}
    end
  end

  defp dictate_target(payload) do
    case VoiceJoinPayload.parse(payload) do
      :legacy ->
        {:ok, nil}

      {:ok, %{target: target, surface: surface}} ->
        with :ok <- VoiceTargets.validate(target, surface), do: {:ok, %{target: target, surface: surface}}

      {:error, :invalid_payload} ->
        refuse("Voice request is invalid.", "invalid_payload")
    end
  end

  defp refuse(reason, code), do: {:error, %{reason: reason, reason_code: code}}

  defp join_stt(socket, generation, lease, topic, target) do
    case start_stt() do
      {:ok, session} ->
        {:ok,
         socket
         |> assign(:stt, session)
         |> assign(:voice_target, target && target.target)
         |> assign(:voice_surface, target && target.surface)
         |> assign(:voice_mode, if(topic == "voice:conversation", do: :conversation, else: :dictation))
         |> assign(:voice_tts, nil)
         |> assign(:voice_tts_spoken?, false)
         |> assign(:voice_generation, generation)
         |> assign(:voice_audio_bytes, 0)
         |> assign(:voice_lease, lease)}

      {:error, code, reason} ->
        :ok = VoiceSessionLimiter.release(lease)
        refuse(reason, code)
    end
  end

  @impl true
  def handle_in("audio", %{"data" => data}, socket) when is_binary(data) do
    case decode_audio(data) do
      {:ok, pcm} ->
        audio_bytes = socket.assigns.voice_audio_bytes + byte_size(pcm)

        if audio_bytes <= max_session_audio_bytes() do
          Voice.push(socket.assigns.stt, data)
          {:noreply, assign(socket, :voice_audio_bytes, audio_bytes)}
        else
          push_error(socket, "error", "Dictation reached the five-minute limit. Review the text and start again.", "session_limit")
          {:stop, :normal, socket}
        end

      {:error, code, reason} ->
        push_error(socket, "error", reason, code)
        {:noreply, socket}
    end
  end

  def handle_in("audio", _payload, socket) do
    push_error(socket, "error", "Audio chunk encoding is invalid.", "invalid_payload")
    {:noreply, socket}
  end

  @impl true
  def handle_in("stop", _payload, socket) do
    case socket.assigns.stt do
      %{pid: _pid} = session -> Voice.commit(session)
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
        push_error(socket, "audio_error", tts_error(reason), VoiceReasonCode.tts(reason))
        {:noreply, socket}
    end
  end

  def handle_in("speak", _payload, %{assigns: %{voice_mode: :conversation}} = socket) do
    push_error(socket, "audio_error", "A voice reply was already requested for this turn.", "invalid_payload")
    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:voice_transcript, kind, text}, socket) when kind in [:partial, :final] and is_binary(text) do
    push(socket, "transcript", %{"kind" => Atom.to_string(kind), "text" => text})
    {:noreply, socket}
  end

  def handle_info({:voice_error, %{message: reason} = error}, socket) when is_binary(reason) do
    push_error(socket, "error", reason, VoiceReasonCode.provider(error))
    {:noreply, socket}
  end

  def handle_info({:voice_error, reason}, socket) when is_binary(reason) do
    push_error(socket, "error", reason, VoiceReasonCode.provider(reason))
    {:noreply, socket}
  end

  def handle_info({:voice_closed}, socket) do
    push(socket, "stopped", %{})
    {:noreply, release_stt(socket)}
  end

  def handle_info({:voice_audio, :chunk, data}, socket) when is_binary(data) do
    push(socket, "audio", %{"data" => Base.encode64(data), "format" => "pcm_44100"})
    {:noreply, socket}
  end

  def handle_info({:voice_audio, :done}, socket) do
    push(socket, "audio_done", %{})
    {:noreply, socket |> assign(:voice_tts, nil) |> release_voice_lease()}
  end

  def handle_info({:voice_audio, :error, reason}, socket) when is_binary(reason) do
    push_error(socket, "audio_error", reason, VoiceReasonCode.provider(reason))
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
      %{pid: pid} = session when is_pid(pid) ->
        Voice.stop(session)

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

  defp push_error(socket, event, reason, code), do: push(socket, event, %{"reason" => reason, "reason_code" => code})

  defp start_stt do
    case Voice.start_transcription(owner: self()) do
      {:ok, session} ->
        {:ok, session}

      {:error, :not_installed} ->
        {:error, "not_installed", @voice_not_installed_reason}

      {:error, :unconfigured} ->
        {:error, "unconfigured", "ElevenLabs speech-to-text is not configured. Dictation is unavailable; ask the Executor to run `aiur init` and add an ElevenLabs API key."}

      {:error, reason} ->
        Logger.warning("voice dictation: transcription session failed to start: #{inspect(reason)}")
        {:error, "provider_unavailable", "Speech-to-text could not start. Check the daemon log and retry."}
    end
  rescue
    error ->
      Logger.warning("voice dictation: STT setup failed: #{inspect(error)}")
      {:error, "provider_unavailable", "Speech-to-text is unavailable right now."}
  catch
    _kind, _reason ->
      {:error, "provider_unavailable", "Speech-to-text is unavailable right now."}
  end

  defp start_tts(text) do
    Voice.start_speech(self(), text, [])
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp start_bounded_tts(socket, text) do
    authority = socket.assigns.voice_authority.connection_generation

    with {:ok, lease} <- VoiceSessionLimiter.acquire(authority) do
      case start_tts(text) do
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

  defp tts_error(:not_installed), do: @voice_not_installed_reason

  defp tts_error(:empty_text), do: "There is no agent reply to speak."
  defp tts_error(:text_too_large), do: "This agent reply is too long to speak."
  defp tts_error(:capacity), do: "Too many dashboard voice replies are active. Try again shortly."
  defp tts_error(_reason), do: "Voice playback could not start."

  defp decode_audio(data) do
    if byte_size(data) > @max_audio_base64_bytes do
      {:error, "chunk_too_large", "Audio chunk is too large."}
    else
      case Base.decode64(data) do
        {:ok, pcm} when byte_size(pcm) <= @max_audio_bytes -> {:ok, pcm}
        {:ok, _pcm} -> {:error, "chunk_too_large", "Audio chunk is too large."}
        :error -> {:error, "invalid_payload", "Audio chunk encoding is invalid."}
      end
    end
  end

  defp max_session_audio_bytes do
    EndpointConfig.get(:voice_max_session_audio_bytes) || @default_max_session_audio_bytes
  end
end
