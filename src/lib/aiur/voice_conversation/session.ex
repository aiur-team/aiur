defmodule Aiur.VoiceConversation.Session do
  @moduledoc "Owns one prototype voice session through browser disconnect and Executor handoff."
  use GenServer

  require Logger

  alias Aiur.VoiceConversation
  alias Aiur.VoiceConversation.Handoff
  alias Elixir.VoiceConverse.Events

  @spec start(pid(), keyword()) :: {:ok, pid(), String.t()} | {:error, term()}
  def start(owner, opts \\ []) do
    case GenServer.start(__MODULE__, {owner, opts}) do
      {:ok, pid} -> {:ok, pid, GenServer.call(pid, :id)}
      error -> error
    end
  end

  @spec audio(pid(), String.t()) :: :ok
  def audio(pid, data), do: GenServer.cast(pid, {:audio, data})

  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.cast(pid, :stop)

  @impl true
  def init({owner, opts}) do
    Process.monitor(owner)
    instance = Keyword.get(opts, :instance, VoiceConversation.Instance)
    start = Keyword.get(opts, :start_session, &VoiceConversation.start_session/2)

    with {:ok, id} <- start.(self(), Keyword.drop(opts, [:instance, :start_session, :deliver])),
         {:ok, session} <- Elixir.VoiceConverse.SessionRegistry.lookup(instance, id) do
      monitor = Process.monitor(session)
      {:ok, %{owner: owner, id: id, instance: instance, monitor: monitor, turns: [], pending_user: nil, deliver: Keyword.get(opts, :deliver, &Handoff.deliver/3), stopping?: false}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:id, _from, state), do: {:reply, state.id, state}

  @impl true
  def handle_cast({:audio, data}, %{stopping?: false} = state) do
    Elixir.VoiceConverse.push_audio(state.instance, state.id, data)
    {:noreply, state}
  end

  def handle_cast({:audio, _data}, state), do: {:noreply, state}
  def handle_cast(:stop, state), do: {:noreply, end_session(state)}

  @impl true
  def handle_info({:voice_conversation, id, {:ended, reason}}, %{id: id} = state), do: finish(state, reason)

  def handle_info({:voice_conversation, id, event}, %{id: id} = state) do
    notify(state, event)
    {:noreply, record(state, event)}
  end

  def handle_info({:voice_conversation_state, id, name}, %{id: id} = state) do
    notify(state, {:state, name})
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state),
    do: finish(state, :transport_lost)

  def handle_info({:DOWN, _monitor, :process, owner, _reason}, %{owner: owner} = state),
    do: {:noreply, end_session(state)}

  def handle_info(_message, state), do: {:noreply, state}

  defp end_session(%{stopping?: true} = state), do: state

  defp end_session(state) do
    case Elixir.VoiceConverse.end_session(state.instance, state.id) do
      :ok ->
        %{state | stopping?: true}

      {:error, :not_found} ->
        send(self(), {:voice_conversation, state.id, {:ended, :transport_lost}})
        state
    end
  end

  defp finish(state, reason) do
    turns = if state.pending_user, do: state.turns ++ [%{role: "user", text: state.pending_user}], else: state.turns

    case state.deliver.(state.id, turns, reason) do
      {:ok, receipt} ->
        notify(state, {:receipt, receipt})

      {:error, _reason} ->
        Logger.warning("Executor voice handoff failed", session_id: state.id)
        notify(state, {:handoff_failed, :delivery_failed})
    end

    notify(state, {:ended, reason})
    {:stop, :normal, state}
  end

  defp record(state, %Events.UserTranscript{text: text, final?: false}),
    do: %{state | pending_user: Elixir.VoiceConverse.Redact.redact(text)}

  defp record(state, %Events.UserTranscript{text: text, final?: true}),
    do: %{state | pending_user: nil, turns: state.turns ++ [%{role: "user", text: Elixir.VoiceConverse.Redact.redact(text)}]}

  defp record(state, %Events.AgentText{text: text, turn_id: id, final?: true}) do
    turn = %{role: "agent", text: Elixir.VoiceConverse.Redact.redact(text), turn_id: id}
    turns = Enum.reject(state.turns, &(&1[:role] == "agent" and id != nil and &1[:turn_id] == id))
    %{state | turns: turns ++ [turn]}
  end

  defp record(state, _event), do: state
  defp notify(state, event), do: send(state.owner, {:executor_voice, event})
end
