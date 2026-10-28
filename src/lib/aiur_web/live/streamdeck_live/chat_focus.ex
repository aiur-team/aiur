defmodule AiurWeb.StreamdeckLive.ChatFocus do
  @moduledoc "Apply shared navigation effects in the emulator's owning process."
  alias AiurWeb.Streamdeck.Deck.{Chat, Nav}
  alias AiurWeb.StreamdeckLive.Modes

  @spec apply(Phoenix.LiveView.Socket.t(), [Nav.effect()]) :: Phoenix.LiveView.Socket.t()
  def apply(socket, effects) do
    Enum.reduce(effects, socket, fn
      {:open_ticket, id}, socket ->
        socket |> Modes.select_agent_from_params(%{"identifier" => id}) |> Modes.enter_cmd(%{"identifier" => id}) |> Chat.open(id)

      :close_ticket, socket ->
        Chat.clear(socket)

      _, socket ->
        socket
    end)
  end
end
