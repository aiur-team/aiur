defmodule AiurWeb.Streamdeck.FrameUpdates do
  @moduledoc false
  alias AiurWeb.Streamdeck.{Deck, Render}
  alias AiurWeb.Streamdeck.Deck.{Input, Nav, PriorityInput}
  alias AiurWeb.Streamdeck.Render.Chat, as: ChatRender
  alias AiurWeb.{StreamdeckFleetUpdates, StreamdeckProjection}
  import Phoenix.Socket, only: [assign: 2]

  @spec input(term(), Phoenix.Socket.t()) :: {:reply, tuple(), Phoenix.Socket.t()}
  def input(raw, socket) do
    case transition(socket.assigns.deck_nav, raw, grid(socket)) do
      {:ok, nav, effects} ->
        dispatch(effects)
        socket = assign(socket, deck_nav: nav, deck_effects: effects, deck_toast: nil)
        {:noreply, socket} = StreamdeckFleetUpdates.schedule(socket)

        PriorityInput.reply(
          socket,
          %{"view" => Atom.to_string(nav.view), "page" => Nav.page(nav)},
          effects
        )

      :noop ->
        {:reply, {:ok, %{}}, socket}

      :error ->
        {:reply, {:error, %{reason: "invalid_input"}}, socket}
    end
  end

  @doc "Apply raw deck input to channel or browser navigation using the same mapping."
  @spec transition(Nav.t(), term(), map()) :: {:ok, Nav.t(), [Nav.effect()]} | :noop | :error
  def transition(previous, raw, grid) do
    with {:ok, input} <- normalize(raw),
         true <- Nav.valid_input?(input),
         {%Nav{} = nav, effects} <-
           Input.reduce(previous, input, Deck.navigation(normalize_grid(grid))) do
      effects = focus_effects(previous, input, effects)
      {:ok, nav, effects}
    else
      :noop -> :noop
      _invalid -> :error
    end
  end

  defp focus_effects(nav, %{"kind" => "dial_press", "index" => 0}, effects) do
    if nav.surface in [:logs, :settings, :commands] and is_binary(nav.selected), do: [{:open_ticket, nav.selected} | effects], else: [:close_ticket | effects]
  end

  defp focus_effects(_nav, %{"kind" => kind, "index" => 3}, effects) when kind in ["dial_press", "dial_long_press", "dial_turn"], do: [:close_ticket | effects]
  defp focus_effects(_nav, _input, effects), do: effects

  @spec push(Phoenix.Socket.t()) :: Phoenix.Socket.t()
  def push(socket) do
    {nav, images} = render(socket)
    Phoenix.Channel.push(socket, "frame", images)
    assign(socket, deck_nav: nav, deck_toast: nil)
  end

  @spec frame(Phoenix.Socket.t()) :: map()
  def frame(socket), do: socket |> render() |> elem(1)

  defp render(socket) do
    {nav, _model, images} =
      frame(
        socket.assigns.deck_nav,
        grid(socket),
        socket.assigns[:deck_usage] || %{},
        &Render.frame/1,
        %{toast: socket.assigns[:deck_toast], chat: socket.assigns[:deck_chat_view]}
      )

    {nav, images}
  end

  @doc "Compose the same frame model for a channel socket or the browser emulator."
  @spec frame(Nav.t(), map(), map(), (map() -> map()), map()) :: {Nav.t(), map(), map()}
  def frame(nav, grid, usage, renderer \\ &Render.frame/1, context \\ %{}) do
    grid = normalize_grid(grid)
    sections = Deck.navigation(grid)
    nav = Nav.clamp(nav, Input.sizes(nav, sections))
    agents = visible_items(nav, sections, grid.agents)

    model =
      Map.merge(
        %{
          grid: %{grid | agents: agents},
          usage: usage,
          page: Nav.page(nav),
          provider_offset: nav.scroll,
          surface: nav.surface
        },
        context
      )

    images = renderer.(model)
    images = if context[:chat] && not is_binary(context[:toast]), do: Map.put(images, :strip, ChatRender.strip(context.chat, System.system_time(:millisecond))), else: images
    {nav, model, images}
  end

  @doc "Deliver shared focus effects in the owning channel or LiveView process."
  @spec dispatch([Nav.effect()]) :: :ok
  def dispatch(effects) do
    Enum.each(effects, fn
      {:open_ticket, id} -> send(self(), {:streamdeck_frame_focus, id})
      :close_ticket -> send(self(), :streamdeck_frame_unfocus)
      _ -> :ok
    end)
  end

  defp grid(socket), do: normalize_grid(socket.assigns[:deck_grid] || StreamdeckProjection.grid())

  defp normalize_grid(grid) do
    agents = Map.get(grid, :agents, Map.get(grid, "agents", []))

    agents =
      Enum.map(agents, fn face ->
        face
        |> Map.put(:identifier, face[:identifier] || face["identifier"])
        |> Map.put(:bucket, face[:bucket] || face["bucket"])
      end)

    Map.put(grid, :agents, agents)
  end

  defp visible_items(%{view: :ticket, stack: []}, _sections, agents), do: agents

  defp visible_items(%{view: view, stack: stack}, sections, agents) do
    items =
      case stack do
        [] ->
          Map.get(sections, view, [])

        [{kind, id} | _rest] ->
          sections |> Map.get(kind, []) |> Enum.find(%{}, &(&1.id == id)) |> Map.get(:tickets, [])
      end

    Enum.map(items, fn item ->
      Enum.find(agents, &(&1.identifier == item.id)) ||
        %{identifier: item.id, title: item.id, bucket: Map.get(item, :bucket, item.id)}
    end)
  end

  defp normalize(%{"kind" => "key", "index" => index, "action" => action}) when index in 0..7 do
    case action do
      "down" -> {:ok, %{"kind" => "key_press", "index" => rem(index, 4) * 2 + div(index, 4)}}
      "up" -> :noop
      _invalid -> :error
    end
  end

  defp normalize(%{"kind" => "dial", "index" => index, "action" => action} = input)
       when index in 0..3 do
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
