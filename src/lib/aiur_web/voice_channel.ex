defmodule AiurWeb.VoiceChannel do
  @moduledoc """
  Browser dictation channel: the second producer feeding the shared
  ElevenLabs transcription path.

  The browser captures audio with `getUserMedia` (it cannot run the Node
  sidecar's PipeWire capture), pushes raw PCM chunks here, and this channel
  owns a server-side `Aiur.ElevenLabs.STT` session. Transcript frames are
  streamed back to the browser so the composer shows live partial text and
  settles to finals; the operator still presses Send in the drawer — nothing
  here ever auto-sends.

  The ElevenLabs API key never reaches the browser: it is resolved server-side
  and travels only inside the STT session's request header.
  """

  use Phoenix.Channel

  require Logger

  alias Aiur.ElevenLabs.STT
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
        "voice:dictation",
        _payload,
        %{
          assigns: %{
            voice_authority: %{
              configuration_generation: generation,
              connection_generation: connection_generation
            }
          }
        } = socket
      ) do
    :ok = FinancialDataAccess.subscribe_to_configuration_changes()

    with true <- Endpoint.config(:dashboard_writable) == true,
         {:ok, ^generation} <- FinancialDataAccess.current_configuration_generation(),
         {:ok, lease} <- VoiceSessionLimiter.acquire(connection_generation) do
      join_stt(socket, generation, lease)
    else
      false -> {:error, %{reason: "Dashboard writing is disabled."}}
      {:error, :capacity} -> {:error, %{reason: "Too many dashboard dictation sessions are active. Close another microphone and retry."}}
      _stale_or_invalid -> {:error, %{reason: "Dashboard authentication changed. Reload and sign in again."}}
    end
  end

  def join("voice:dictation", _payload, _socket), do: {:error, %{reason: "unauthorized"}}

  def join(_topic, _payload, _socket), do: {:error, %{reason: "invalid_topic"}}

  defp join_stt(socket, generation, lease) do
    case start_stt(socket) do
      {:ok, %{pid: pid}} ->
        {:ok,
         socket
         |> assign(:stt, %{pid: pid})
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
          STT.push(socket.assigns.stt.pid, pcm)
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
      %{pid: pid} -> STT.commit(pid)
      nil -> push(socket, "stopped", %{"text" => ""})
    end

    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:stt_transcript, kind, text}, socket) when kind in [:partial, :final] and is_binary(text) do
    push(socket, "transcript", %{"kind" => Atom.to_string(kind), "text" => text})
    {:noreply, socket}
  end

  def handle_info({:stt_error, reason}, socket) when is_binary(reason) do
    push(socket, "error", %{"reason" => reason})
    {:noreply, socket}
  end

  def handle_info({:stt_stopped, :ok}, socket) do
    push(socket, "stopped", %{})
    {:noreply, socket}
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
        STT.stop(pid)

      _ ->
        :ok
    end

    case socket.assigns[:voice_lease] do
      lease when is_reference(lease) -> VoiceSessionLimiter.release(lease)
      _missing -> :ok
    end

    :ok
  end

  # --- helpers -------------------------------------------------------------

  # The STT session is injected through the endpoint config so channel tests
  # drive a fake transcriber; production uses `Aiur.ElevenLabs.STT` backed by
  # the configured API key.
  defp start_stt(socket) do
    case Endpoint.config(:voice_stt_start_fun) do
      fun when is_function(fun, 1) ->
        safe_start(fun, socket)

      _ ->
        start_real_stt()
    end
  end

  defp start_real_stt do
    case Aiur.Config.elevenlabs_api_key() do
      nil ->
        {:error, "ElevenLabs speech-to-text is not configured. Dictation is unavailable; ask the Executor to run `aiur init` and add an ElevenLabs API key."}

      api_key ->
        case STT.start_link(
               owner: self(),
               api_key: api_key,
               language_code: Aiur.Config.elevenlabs_language_code()
             ) do
          {:ok, pid} ->
            {:ok, %{pid: pid}}

          {:error, reason} ->
            Logger.warning("voice dictation: ElevenLabs STT session failed to start: #{inspect(reason)}")
            {:error, "Speech-to-text could not start. Check the daemon log and retry."}
        end
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
      {:ok, %{pid: pid}} when is_pid(pid) -> {:ok, %{pid: pid}}
      {:error, _reason} = error -> error
      _other -> {:error, "Speech-to-text could not start."}
    end
  catch
    _kind, _reason -> {:error, "Speech-to-text could not start."}
  end

  defp decode_audio(data) do
    cond do
      byte_size(data) > @max_audio_base64_bytes ->
        {:error, "Audio chunk is too large."}

      true ->
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
