defmodule AiurWeb.Streamdeck.Deck.PriorityInput do
  @moduledoc false
  alias AiurWeb.Streamdeck.Deck.Priority
  alias AiurWeb.{StreamdeckFleetUpdates, StreamdeckProjection}
  import Phoenix.Socket, only: [assign: 2]

  @spec reply(Phoenix.Socket.t(), map(), list()) :: {:reply, {:ok | :error, map()}, Phoenix.Socket.t()}
  def reply(socket, navigation, [{:priority, id, direction, ticks}]) do
    if socket.assigns[:streamdeck_authenticated] == true do
      result = Priority.step(id, direction, ticks)

      toast =
        case result do
          {:ok, :at_edge} -> "already at queue edge"
          {:ok, %{position: position}} -> "Queued ##{position + 1}"
          {:error, reason} -> Priority.message(reason)
        end

      socket = assign(socket, deck_grid: StreamdeckProjection.grid(), deck_toast: toast)
      {:noreply, socket} = StreamdeckFleetUpdates.schedule(socket)

      case result do
        {:ok, _position} -> {:reply, {:ok, navigation}, socket}
        {:error, reason} -> {:reply, {:error, %{reason: reason_text(reason)}}, socket}
      end
    else
      {:reply, {:error, %{reason: "unauthorized"}}, socket}
    end
  end

  def reply(socket, navigation, _effects), do: {:reply, {:ok, navigation}, socket}
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
