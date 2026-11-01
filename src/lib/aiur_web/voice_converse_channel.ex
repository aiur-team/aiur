defmodule AiurWeb.VoiceConverseChannel do
  @moduledoc "Authenticated dashboard adapter for full-duplex VoiceConverse sessions."
  use Phoenix.Channel

  alias AiurWeb.{EndpointConfig, FinancialDataAccess, VoiceSessionLimiter}
  alias AiurWeb.VoiceConverse.{Frames, Join}
  alias VoiceConverse.EventFrames

  @tools ~w(get_status get_details list_open_commands propose_instruction ask_agent record_summary end_conversation)

  @impl true
  def join("voice:converse", payload, %{assigns: %{voice_authority: authority}} = socket) do
    :ok = FinancialDataAccess.subscribe_to_configuration_changes()

    with :ok <- writable(),
         {:ok, generation} <- FinancialDataAccess.current_configuration_generation(),
         true <- generation == authority.configuration_generation,
         {:ok, parsed} <- Join.parse(payload),
         :ok <- Join.validate(parsed.target),
         :ok <- Join.available(),
         {:ok, target} <- Join.target(parsed.target),
         instance = EndpointConfig.get(:voice_converse_instance, Aiur.VoiceConversation.Instance),
         key = {generation, authority.connection_generation, parsed.target, parsed.client_session_id},
         {:ok, lease} <- acquire(instance, key, authority.connection_generation) do
      start(socket, target, generation, lease, instance, key)
    else
      false -> Join.error(:auth_changed)
      {:error, %{} = refusal} -> {:error, refusal}
      {:error, reason} -> Join.error(reason)
    end
  end

  def join(_, _, _), do: Join.error(:auth_changed)

  defp writable do
    if EndpointConfig.get(:dashboard_writable) == true, do: :ok, else: Join.error(:read_only)
  end

  defp acquire(instance, key, authority) do
    if Process.whereis(VoiceConverse.SessionRegistry.name(instance)) do
      acquire_running(instance, key, authority)
    else
      {:error, :not_installed}
    end
  end

  defp acquire_running(instance, key, authority) do
    owner =
      case VoiceConverse.SessionRegistry.client(instance, key) do
        {:ok, pid, _, _} -> pid
        :error -> self()
      end

    VoiceSessionLimiter.acquire_session(authority, owner)
  end

  defp start(socket, target, generation, lease, instance, key) do
    case VoiceConverse.start_session(instance, target, client: self(), client_session_key: key, allowed_tools: @tools) do
      {:ok, id} ->
        {:ok, pid} = VoiceConverse.SessionRegistry.lookup(instance, id)
        :ok = VoiceSessionLimiter.transfer(lease, pid)
        socket = assign(socket, instance: instance, conversation_id: id, generation: generation, lease: lease, monitor: Process.monitor(pid))
        {:ok, %{conversation_id: id}, socket}

      {:error, reason} ->
        VoiceSessionLimiter.release(lease)
        Join.error(reason)
    end
  catch
    :exit, _ ->
      VoiceSessionLimiter.release(lease)
      Join.error(:provider_unavailable)
  end

  @impl true
  def handle_in(event, payload, socket) do
    case Frames.input(event, payload, socket.assigns) do
      :ok ->
        {:noreply, socket}

      {:ok, _} ->
        {:noreply, socket}

      {:error, reason} ->
        {:error, refusal} = Join.error(reason)
        Frames.push(socket, EventFrames.frames({:error, refusal.reason_code, refusal.reason}))
        {:noreply, socket}
    end
  catch
    :exit, _ -> {:stop, :normal, socket}
  end

  @impl true
  def handle_info({:voice_conversation_state, id, state}, %{assigns: %{conversation_id: id}} = socket),
    do: relay(socket, {:state, state})

  def handle_info({:voice_conversation, id, {:state, _}}, %{assigns: %{conversation_id: id}} = socket), do: {:noreply, socket}

  def handle_info({:voice_conversation, id, event}, %{assigns: %{conversation_id: id}} = socket), do: relay(socket, event)

  def handle_info({FinancialDataAccess, :configuration_changed, generation}, %{assigns: %{generation: generation}} = socket),
    do: {:noreply, socket}

  def handle_info({FinancialDataAccess, :configuration_changed, _}, socket) do
    VoiceConverse.end_session(socket.assigns.instance, socket.assigns.conversation_id, :auth_changed)
    {:stop, :normal, socket}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{assigns: %{monitor: ref}} = socket) do
    VoiceSessionLimiter.release(socket.assigns.lease)
    {:stop, :normal, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp relay(socket, {:ended, _reason} = event) do
    push(socket, "audio_done", %{})
    Frames.push(socket, EventFrames.frames(event))
    {:noreply, socket}
  end

  defp relay(socket, event) do
    Frames.push(socket, EventFrames.frames(event))
    {:noreply, socket}
  end

  @impl true
  def terminate(_, %{assigns: %{instance: instance, conversation_id: id, lease: _lease}}) do
    VoiceConverse.unsubscribe(instance, id, self())
    :ok
  catch
    :exit, _ -> :ok
  end

  def terminate(_, _), do: :ok
end
