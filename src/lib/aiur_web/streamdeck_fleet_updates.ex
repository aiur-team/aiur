defmodule AiurWeb.StreamdeckFleetUpdates do
  @moduledoc false
  import Phoenix.Socket, only: [assign: 3]
  alias Aiur.AgentPubSub
  alias AiurWeb.StreamdeckProjection

  @spec subscribe(:atomics.atomics_ref()) :: :ok | {:error, term()}
  def subscribe(latch) do
    subscriber = AiurWeb.Endpoint.config(:streamdeck_fleet_subscribe_fun) || (&AgentPubSub.subscribe_fleet_refresh/1)
    subscriber.(latch)
  end

  @spec schedule(Phoenix.Socket.t()) :: {:noreply, Phoenix.Socket.t()}
  def schedule(%{assigns: %{fleet_flush: nil}} = socket) do
    token = make_ref()
    Process.send_after(self(), {:flush_fleet, token}, 250)
    {:noreply, assign(socket, :fleet_flush, token)}
  end

  def schedule(socket), do: {:noreply, socket}

  @spec flush(Phoenix.Socket.t(), reference()) :: {:noreply, Phoenix.Socket.t()}
  def flush(%{assigns: %{fleet_flush: token}} = socket, token) when is_reference(token) do
    :atomics.put(socket.assigns.fleet_latch, 1, 0)
    Phoenix.Channel.push(socket, "fleet", StreamdeckProjection.fleet_with_grid(AgentPubSub.latest_fleet_summaries()))
    {:noreply, assign(socket, :fleet_flush, nil)}
  end

  def flush(socket, _old_token), do: {:noreply, socket}
end
