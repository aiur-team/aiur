defmodule AiurWeb.StreamdeckLive.TicketActions do
  @moduledoc false
  import Phoenix.Component, only: [assign: 3]
  alias AiurWeb.Streamdeck.Deck.Priority
  alias AiurWeb.StreamdeckLive.Env

  @spec priority(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def priority(socket, command) do
    if Env.dashboard_writable?() and socket.assigns.sd_mode == :cmd and socket.assigns.sd_active do
      direction = if command == "priority_up", do: :up, else: :down
      result = Priority.step(to_string(socket.assigns.sd_active.identifier), direction)

      message =
        case result do
          {:ok, :at_edge} -> "already at queue edge"
          {:ok, %{position: position}} -> "Queued ##{position + 1}"
          {:error, reason} -> Priority.message(reason)
        end

      assign(socket, :control_feedback, message)
    else
      socket
    end
  end
end
