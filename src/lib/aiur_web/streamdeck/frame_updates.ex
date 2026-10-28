defmodule AiurWeb.Streamdeck.FrameUpdates do
  @moduledoc false
  alias AiurWeb.Streamdeck.{Deck, Render}
  alias AiurWeb.Streamdeck.Deck.{Input, Nav}
  alias AiurWeb.{StreamdeckFleetUpdates, StreamdeckProjection}
  import Phoenix.Socket, only: [assign: 2, assign: 3]

  @spec input(term(), Phoenix.Socket.t()) :: {:reply, tuple(), Phoenix.Socket.t()}
  def input(raw, socket) do
    with {:ok, input} <- normalize(raw),
         true <- Nav.valid_input?(input) do
      sections = StreamdeckProjection.grid() |> Deck.navigation()
      {nav, effects} = Input.reduce(socket.assigns.deck_nav, input, sections)
      socket = assign(socket, deck_nav: nav, deck_effects: effects)
      {:noreply, socket} = StreamdeckFleetUpdates.schedule(socket)
      {:reply, {:ok, %{"view" => Atom.to_string(nav.view), "page" => Nav.page(nav)}}, socket}
    else
      :noop ->
        {:reply, {:ok, %{}}, socket}

      _invalid ->
        {:reply, {:error, %{reason: "invalid_input"}}, socket}
    end
  end

  @spec push(Phoenix.Socket.t()) :: Phoenix.Socket.t()
  def push(socket) do
    grid = StreamdeckProjection.grid()
    sections = Deck.navigation(grid)
    nav = Nav.clamp(socket.assigns.deck_nav, Input.sizes(socket.assigns.deck_nav, sections))
    agents = visible_items(nav, sections, grid.agents)
    model = %{grid: %{grid | agents: agents}, usage: socket.assigns.deck_usage, page: Nav.page(nav), provider_offset: nav.scroll}
    Phoenix.Channel.push(socket, "frame", Render.frame(model))
    assign(socket, :deck_nav, nav)
  end

  defp visible_items(%{view: :ticket, stack: []}, _sections, agents), do: agents

  defp visible_items(%{view: view, stack: stack}, sections, agents) do
    items =
      case stack do
        [] -> Map.get(sections, view, [])
        [{kind, id} | _rest] -> sections |> Map.get(kind, []) |> Enum.find(%{}, &(&1.id == id)) |> Map.get(:tickets, [])
      end

    Enum.map(items, fn item ->
      Enum.find(agents, &(&1.identifier == item.id)) || %{identifier: item.id, title: item.id, bucket: Map.get(item, :bucket, item.id)}
    end)
  end

  defp normalize(%{"kind" => "key", "index" => index, "action" => action}) when index in 0..7 do
    case action do
      "down" -> {:ok, %{"kind" => "key_press", "index" => rem(index, 4) * 2 + div(index, 4)}}
      "up" -> :noop
      _invalid -> :error
    end
  end

  defp normalize(%{"kind" => "dial", "index" => index, "action" => action} = input) when index in 0..3 do
    case action do
      "turn" -> {:ok, %{"kind" => "dial_turn", "index" => index, "ticks" => input["delta"]}}
      "press" -> {:ok, %{"kind" => "dial_press", "index" => index}}
      "long_press" -> {:ok, %{"kind" => "dial_long_press", "index" => index}}
      edge when edge in ["down", "up"] -> :noop
      _invalid -> :error
    end
  end

  defp normalize(%{"kind" => "touch", "index" => index, "action" => "tap", "x" => x})
       when is_integer(index) and index in 0..3 and is_integer(x) and x in 0..799,
       do: :noop

  defp normalize(input), do: {:ok, input}
end
