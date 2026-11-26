defmodule AiurWeb.Streamdeck.Deck.ChatOwner do
  @moduledoc "Owner-specific delivery for the shared channel and emulator conversation controller."

  @type socket :: Phoenix.Socket.t() | Phoenix.LiveView.Socket.t()

  @spec assign(socket(), keyword()) :: socket()
  def assign(%Phoenix.Socket{} = socket, values), do: Phoenix.Socket.assign(socket, values)
  def assign(%Phoenix.LiveView.Socket{} = socket, values), do: Phoenix.Component.assign(socket, values)

  @spec publish(socket(), map()) :: socket()
  def publish(%Phoenix.Socket{} = socket, message) do
    Phoenix.Channel.push(socket, "chat", message)
    {:noreply, socket} = socket |> assign(deck_chat_view: message) |> AiurWeb.StreamdeckFleetUpdates.schedule()
    socket
  end

  def publish(%Phoenix.LiveView.Socket{} = socket, message), do: assign(socket, deck_chat_view: message)
end
