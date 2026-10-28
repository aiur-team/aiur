defmodule AiurWeb.Streamdeck.UsageUpdates do
  @moduledoc false
  import Phoenix.Socket, only: [assign: 3]
  alias AiurWeb.Streamdeck.Deck.Meters

  @spec schedule(Phoenix.Socket.t()) :: {:noreply, Phoenix.Socket.t()}
  def schedule(%{assigns: %{usage_flush: nil}} = socket) do
    token = make_ref()
    Process.send_after(self(), {:flush_usage, token}, 250)
    {:noreply, assign(socket, :usage_flush, token)}
  end

  def schedule(socket), do: {:noreply, socket}

  @spec flush(Phoenix.Socket.t(), reference()) :: {:noreply, Phoenix.Socket.t()}
  def flush(%{assigns: %{usage_flush: token}} = socket, token) when is_reference(token) do
    Phoenix.Channel.push(socket, "usage", Meters.read())
    {:noreply, assign(socket, :usage_flush, nil)}
  end

  def flush(socket, _old_token), do: {:noreply, socket}
end
