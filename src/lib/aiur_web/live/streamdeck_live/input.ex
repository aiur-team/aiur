defmodule AiurWeb.StreamdeckLive.Input do
  @moduledoc "Route device-shaped input to the emulator's existing focused controls."
  import Phoenix.Component, only: [assign: 2]
  alias AiurWeb.Streamdeck.{Deck, FrameUpdates}
  alias AiurWeb.Streamdeck.Deck.Nav
  alias AiurWeb.StreamdeckLive
  alias AiurWeb.StreamdeckLive.{Grid, Modes, Surface}

  @spec handle(map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle(%{"kind" => "dial", "index" => index, "action" => "turn", "delta" => delta}, socket)
      when index in 0..3 and is_integer(delta) and delta in -32..32 do
    case {socket.assigns.sd_mode, index} do
      {:logs, 0} ->
        StreamdeckLive.handle_event(
          "logs-scroll",
          %{"axis" => "transcript", "delta" => delta},
          socket
        )

      {:logs, 3} ->
        StreamdeckLive.handle_event(
          "logs-scroll",
          %{"axis" => "events", "delta" => delta},
          socket
        )

      _ ->
        StreamdeckLive.reduce_input(%{"kind" => "dial", "index" => index, "action" => "turn", "delta" => delta}, socket)
    end
  end

  def handle(%{"kind" => "dial", "index" => 0, "action" => "press"}, socket),
    do: StreamdeckLive.handle_event("dial-press", %{"index" => 0, "action" => "back"}, socket)

  def handle(
        %{"kind" => "dial", "index" => 3, "action" => "press"},
        %{assigns: %{sd_mode: :grid}} = socket
      ),
      do: StreamdeckLive.reduce_input(%{"kind" => "dial", "index" => 3, "action" => "press"}, socket)

  def handle(%{"kind" => "dial", "index" => 3, "action" => "press"}, socket),
    do:
      StreamdeckLive.handle_event(
        "dial-press",
        %{"index" => 3, "action" => "cycle-window"},
        socket
      )

  def handle(raw, socket), do: StreamdeckLive.reduce_input(raw, socket)

  @spec reduce(map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def reduce(raw, socket) do
    case FrameUpdates.transition(socket.assigns.deck_nav, raw, socket.assigns.grid) do
      {:ok, nav, effects} ->
        socket = assign(socket, deck_nav: nav, deck_effects: effects)
        sizes = Deck.Input.sizes(nav, Deck.navigation(socket.assigns.grid))
        total = if nav.stack == [], do: sizes[nav.view], else: sizes.drill
        dial_value = Surface.dial_value_from_offset(Nav.page(nav) * 4, total)
        socket = Grid.assign_grid(socket, socket.assigns.grid, 0, socket.assigns.usage, dial_value)

        socket =
          Enum.reduce(effects, socket, fn
            {:open_ticket, identifier}, socket ->
              params = %{"identifier" => identifier}
              socket |> Modes.select_agent_from_params(params) |> Modes.enter_cmd(params)

            _effect, socket ->
              socket
          end)

        {:noreply, socket}

      _unchanged ->
        {:noreply, socket}
    end
  end
end
