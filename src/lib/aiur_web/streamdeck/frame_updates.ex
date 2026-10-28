defmodule AiurWeb.Streamdeck.FrameUpdates do
  @moduledoc false
  alias AiurWeb.Streamdeck.{Deck, Render}
  alias AiurWeb.Streamdeck.Render.Chat, as: ChatRender
  alias AiurWeb.Streamdeck.Deck.{Input, Nav, PriorityInput}
  alias AiurWeb.{StreamdeckFleetUpdates, StreamdeckProjection}
  import Phoenix.Socket, only: [assign: 2]

  @spec input(term(), Phoenix.Socket.t()) :: {:reply, tuple(), Phoenix.Socket.t()}
  def input(raw, socket) do
    with {:ok, input} <- normalize(raw),
         true <- Nav.valid_input?(input) do
      sections = socket |> grid() |> Deck.navigation()
      {nav, effects} = Input.reduce(socket.assigns.deck_nav, input, sections)

      Enum.each(effects, fn
        {:open_ticket, id} -> send(self(), {:streamdeck_frame_focus, id})
        _effect -> :ok
      end)

      if input["kind"] in ["dial_press", "dial_long_press", "dial_turn"] and input["index"] == 3, do: send(self(), :streamdeck_frame_unfocus)
      socket = assign(socket, deck_nav: nav, deck_effects: effects, deck_toast: nil)
      {:noreply, socket} = StreamdeckFleetUpdates.schedule(socket)
      PriorityInput.reply(socket, %{"view" => Atom.to_string(nav.view), "page" => Nav.page(nav)}, effects)
    else
      :noop ->
        {:reply, {:ok, %{}}, socket}

      _invalid ->
        {:reply, {:error, %{reason: "invalid_input"}}, socket}
    end
  end

  @spec push(Phoenix.Socket.t()) :: Phoenix.Socket.t()
  def push(socket) do
    {nav, frame} = render(socket)
    Phoenix.Channel.push(socket, "frame", frame)
    assign(socket, deck_nav: nav, deck_toast: nil)
  end

  @spec frame(Phoenix.Socket.t()) :: map()
  def frame(socket), do: socket |> render() |> elem(1)

  defp render(socket) do
    grid = grid(socket)
    sections = Deck.navigation(grid)
    nav = Nav.clamp(socket.assigns.deck_nav, Input.sizes(socket.assigns.deck_nav, sections))
    agents = visible_items(nav, sections, grid.agents)
    model = %{grid: %{grid | agents: agents}, usage: socket.assigns[:deck_usage] || %{}, page: Nav.page(nav), provider_offset: nav.scroll, toast: socket.assigns[:deck_toast]}
    frame = Render.frame(model)
    chat = socket.assigns[:deck_chat_view]
    frame = if chat && not is_binary(model.toast), do: Map.put(frame, :strip, ChatRender.strip(chat, System.system_time(:millisecond))), else: frame
    {nav, frame}
  end

  defp grid(socket) do
    grid = socket.assigns[:deck_grid] || StreamdeckProjection.grid()
    agents = Map.get(grid, :agents, Map.get(grid, "agents", []))

    agents =
      Enum.map(agents, fn face ->
        face |> Map.put(:identifier, face[:identifier] || face["identifier"]) |> Map.put(:bucket, face[:bucket] || face["bucket"])
      end)

    Map.put(grid, :agents, agents)
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
