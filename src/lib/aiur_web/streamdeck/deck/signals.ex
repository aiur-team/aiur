defmodule AiurWeb.Streamdeck.Deck.Signals do
  @moduledoc "Forwards focused alerts and controls without passing legacy transcript bursts to the channel."
  use GenServer

  @spec start_link(pid(), String.t()) :: GenServer.on_start()
  def start_link(owner, id), do: GenServer.start_link(__MODULE__, {owner, id})

  @impl true
  def init({owner, id}) do
    :ok = Aiur.AgentPubSub.subscribe_agent(id)
    {:ok, {owner, id}}
  end

  @impl true
  def handle_info({:alert, event}, {owner, id} = state) do
    send(owner, {:streamdeck_alert, id, event})
    {:noreply, state}
  end

  def handle_info({:control_lifecycle, payload}, {owner, id} = state) do
    send(owner, {:streamdeck_control, id, payload})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
