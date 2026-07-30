defmodule AiurWeb.StreamdeckTranscriptRelay do
  @moduledoc false

  use GenServer

  alias Aiur.AgentPubSub

  @spec start_link(pid(), String.t(), pos_integer()) :: GenServer.on_start()
  def start_link(owner, identifier, flush_ms) when is_pid(owner) and is_binary(identifier) and is_integer(flush_ms) do
    GenServer.start_link(__MODULE__, {owner, identifier, flush_ms})
  end

  @impl true
  def init({owner, identifier, flush_ms}) do
    :ok = AgentPubSub.subscribe_agent(identifier)
    {:ok, %{owner: owner, identifier: identifier, flush_ms: flush_ms, pending: nil, timer: nil}}
  end

  @impl true
  def handle_info({:transcript_event, event}, state) do
    timer = state.timer || Process.send_after(self(), :flush, state.flush_ms)
    {:noreply, %{state | pending: event, timer: timer}}
  end

  def handle_info({:alert, event}, state) do
    send(state.owner, {:streamdeck_alert, state.identifier, event})
    {:noreply, state}
  end

  def handle_info({:control_lifecycle, payload}, state) do
    send(state.owner, {:streamdeck_control, state.identifier, payload})
    {:noreply, state}
  end

  def handle_info(:flush, %{pending: event} = state) when is_map(event) do
    send(state.owner, {:streamdeck_transcript, state.identifier, event})
    {:noreply, %{state | pending: nil, timer: nil}}
  end

  def handle_info(:flush, state), do: {:noreply, %{state | timer: nil}}
  def handle_info(_message, state), do: {:noreply, state}
end
