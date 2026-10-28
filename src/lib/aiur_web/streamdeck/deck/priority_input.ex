defmodule AiurWeb.Streamdeck.Deck.PriorityInput do
  @moduledoc false
  alias AiurWeb.Streamdeck.Deck.{MeterPage, Priority}
  alias AiurWeb.Streamdeck.Render
  alias AiurWeb.StreamdeckProjection

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

      nav = socket.assigns[:deck_nav]
      grid = StreamdeckProjection.grid() |> MeterPage.prepare(nav)
      frame = Render.frame(%{grid: grid, toast: toast, nav: nav})

      case result do
        {:ok, :at_edge} -> {:reply, {:ok, Map.merge(navigation, %{"result" => "at_edge", "frame" => frame})}, socket}
        {:ok, position} -> {:reply, {:ok, Map.merge(navigation, %{"position" => position.position, "queue" => position.queue, "frame" => frame})}, socket}
        {:error, reason} -> {:reply, {:error, %{reason: reason_text(reason), frame: frame}}, socket}
      end
    else
      {:reply, {:error, %{reason: "unauthorized"}}, socket}
    end
  end

  def reply(%{assigns: %{deck_nav: %{view: :fleet} = nav}} = socket, navigation, _effects) do
    frame = Render.frame(%{grid: socket.assigns.deck_frame_grid, nav: nav})
    {:reply, {:ok, Map.put(navigation, "frame", frame)}, socket}
  end

  def reply(%{assigns: %{deck_nav: %{view: :ticket}, deck_frame_grid: grid}} = socket, navigation, _effects) do
    {:reply, {:ok, Map.put(navigation, "frame", Render.frame(%{grid: grid}))}, socket}
  end

  def reply(socket, navigation, _effects), do: {:reply, {:ok, navigation}, socket}
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
