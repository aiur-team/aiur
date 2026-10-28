defmodule AiurWeb.ExecutorVoiceChannel do
  @moduledoc "Authenticated, bounded dashboard transport for Executor conversations."
  use Phoenix.Channel

  alias Aiur.VoiceConversation.{Selection, Session}
  alias AiurWeb.{EndpointConfig, FinancialDataAccess, VoiceSessionLimiter}

  @max_chunk 262_144
  @max_encoded 4 * div(@max_chunk + 2, 3)
  @max_total 9_600_000

  @impl true
  def join("voice:executor", payload, %{assigns: %{voice_authority: authority}} = socket) do
    :ok = FinancialDataAccess.subscribe_to_configuration_changes()

    with true <- EndpointConfig.get(:dashboard_writable) == true,
         {:ok, generation} <- FinancialDataAccess.current_configuration_generation(),
         true <- generation == authority.configuration_generation,
         {:ok, opts} <- Selection.options(payload),
         {:ok, lease} <- VoiceSessionLimiter.acquire(authority.connection_generation) do
      start_session(socket, generation, lease, opts)
    else
      {:error, :capacity} -> refuse("Too many voice sessions are active.", "capacity")
      {:error, :unconfigured} -> refuse("Choose a configured provider and model; accept cloud disclosure in voice settings.", "unavailable")
      _ -> refuse("Dashboard authentication changed or writing is disabled.", "auth_changed")
    end
  end

  def join(_topic, _payload, _socket), do: refuse("Unauthorized voice session.", "auth_changed")

  defp start_session(socket, generation, lease, opts) do
    case Session.start(self(), opts) do
      {:ok, pid, id} ->
        {:ok, %{session_id: id}, socket |> assign(:session, pid) |> assign(:monitor, Process.monitor(pid)) |> assign(:generation, generation) |> assign(:lease, lease) |> assign(:bytes, 0)}

      {:error, reason} ->
        VoiceSessionLimiter.release(lease)
        refuse(start_error(reason), "unavailable")
    end
  end

  @impl true
  def handle_in("audio", %{"data" => data}, %{assigns: %{session: pid}} = socket)
      when is_binary(data) and byte_size(data) <= @max_encoded and is_pid(pid) do
    case Base.decode64(data) do
      {:ok, pcm} when byte_size(pcm) > 0 and byte_size(pcm) <= @max_chunk and rem(byte_size(pcm), 2) == 0 ->
        accept_audio(socket, data, byte_size(pcm))

      _ ->
        push(socket, "error", %{reason: "Invalid PCM audio chunk."})
        {:noreply, socket}
    end
  end

  def handle_in("audio", _payload, socket) do
    push(socket, "error", %{reason: "Invalid or oversized audio chunk."})
    {:noreply, socket}
  end

  def handle_in("stop", _payload, socket) do
    stop_session(socket)
    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  defp accept_audio(socket, data, size) do
    bytes = socket.assigns.bytes + size

    if bytes <= @max_total do
      Session.audio(socket.assigns.session, data)
      {:noreply, assign(socket, :bytes, bytes)}
    else
      push(socket, "error", %{reason: "Voice session reached the audio limit."})
      stop_session(socket)
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:executor_voice, {:comparison_saved, id}}, socket) do
    push(socket, "comparison_saved", %{id: id})
    {:noreply, socket}
  end

  def handle_info({:executor_voice, {:receipt, receipt}}, socket) do
    push(socket, "receipt", receipt)
    {:noreply, socket}
  end

  def handle_info({:executor_voice, {:handoff_failed, _reason}}, socket) do
    push(socket, "handoff_failed", %{reason: "Session ended, but the Executor handoff could not be queued."})
    {:noreply, socket}
  end

  def handle_info({:executor_voice, {:error, _code, message}}, socket) do
    push(socket, "error", %{reason: message})
    {:noreply, socket}
  end

  def handle_info({:executor_voice, {:ended, _reason}}, socket) do
    push(socket, "ended", %{})
    {:noreply, socket}
  end

  def handle_info({:executor_voice, {:state, state}}, socket) do
    push(socket, "state", %{state: state})
    {:noreply, socket}
  end

  def handle_info({:executor_voice, event}, socket) when is_struct(event) do
    relay(socket, event)
    {:noreply, socket}
  end

  def handle_info({FinancialDataAccess, :configuration_changed, generation}, %{assigns: %{generation: generation}} = socket),
    do: {:noreply, socket}

  def handle_info({FinancialDataAccess, :configuration_changed, _generation}, socket), do: {:stop, :normal, socket}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{assigns: %{monitor: ref}} = socket) do
    if reason != :normal, do: push(socket, "error", %{reason: "Voice session stopped unexpectedly."})
    push(socket, "ended", %{})
    VoiceSessionLimiter.release(socket.assigns.lease)
    {:noreply, socket |> assign(:session, nil) |> assign(:lease, nil)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Match normalized module names without making the optional package a compile dependency.
  defp relay(socket, %{__struct__: module} = event) do
    case Module.split(module) |> List.last() do
      "AgentAudio" -> push(socket, "audio", %{data: event.data_b64, format: event.format})
      "Interruption" -> push(socket, "interruption", %{})
      "UserTranscript" -> push(socket, "transcript", %{role: "user", text: event.text})
      "AgentText" -> push(socket, "transcript", %{role: "assistant", text: event.text})
      "Error" -> push(socket, "error", %{reason: event.message})
      "Closed" -> :ok
      _ -> :ok
    end
  end

  @impl true
  def terminate(_reason, socket) do
    stop_session(socket)
    if is_reference(socket.assigns[:lease]), do: VoiceSessionLimiter.release(socket.assigns.lease)
    :ok
  end

  defp stop_session(socket) do
    if is_pid(socket.assigns[:session]), do: Session.stop(socket.assigns.session)
  end

  defp start_error(:unconfigured), do: "Executor voice is not configured."
  defp start_error(:not_installed), do: "Executor voice is not installed."
  defp start_error(:cost_cap), do: "This provider has reached its comparison minute cap."
  defp start_error(_), do: "Executor voice could not start."
  defp refuse(reason, code), do: {:error, %{reason: reason, reason_code: code}}
end
