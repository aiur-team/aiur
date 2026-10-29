defmodule AiurWeb.StreamdeckLive.Grid do
  @moduledoc """
  Socket state for the Stream Deck emulator's fleet grid: loading the
  shared ticket sections, windowing them under the page dial, and keeping the
  focused agent and transcript relay. Socket in, socket
  out.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]
  import AiurWeb.StreamdeckLive.Surface

  alias AiurWeb.{
    Endpoint,
    EndpointConfig,
    StreamdeckFleet,
    StreamdeckProjection,
    StreamdeckTranscriptRelay
  }

  alias AiurWeb.Streamdeck.Deck
  alias AiurWeb.Streamdeck.Deck.{Input, Nav, TicketPage}
  alias Phoenix.LiveView.Socket

  @spec refresh_grid(Socket.t()) :: Socket.t()
  def refresh_grid(socket) do
    grid = load_grid()
    usage = StreamdeckProjection.provider_meters()
    previous_identifier = socket.assigns[:selected_identifier]
    dial_value = socket.assigns[:grid_dial_value] || 0
    column_offset = column_offset_from_dial(dial_value, grid.total)
    socket = assign_grid(socket, grid, column_offset, usage, dial_value)

    if connected?(socket) and is_binary(previous_identifier) and
         previous_identifier != socket.assigns.selected_identifier do
      focus_agent(socket, previous_identifier, socket.assigns.selected_identifier)
    else
      socket
    end
  end

  # A meter observation changes only the usage segments on the touch strip, so
  # it must not re-read the fleet. Meter observations arrive far more often than
  # fleet changes (once per rate-limit-bearing response), and `refresh_grid/1`
  # pays a full grid load each time; scoping the update to the screen avoids
  # re-projecting the fleet (and any Orchestrator read) on a topic that can fire
  # every request.
  @spec refresh_meters(Socket.t()) :: Socket.t()
  def refresh_meters(socket) do
    usage = StreamdeckProjection.provider_meters()
    assign(socket, :usage, usage)
  end

  @spec assign_grid(Socket.t(), map(), integer(), map() | nil, number() | nil) :: Socket.t()
  def assign_grid(socket, grid, column_offset, usage, dial_value) do
    {dial_value, _legacy_offset} =
      case dial_value do
        nil ->
          {dial_value_from_offset(column_offset, grid.total), clamp_column_offset(column_offset, grid.total)}

        value ->
          value = clamp(value, 0, 100)
          {value, column_offset_from_dial(value, grid.total)}
      end

    nav =
      Nav.clamp(
        socket.assigns.deck_nav,
        Input.sizes(socket.assigns.deck_nav, Deck.navigation(grid))
      )

    page = Nav.page(nav)
    column_offset = page * 4
    usage = usage || StreamdeckProjection.provider_meters()

    visible_agents =
      Enum.slice(grid.agents, column_offset * grid.rows_per_column, grid.agents_per_page)

    {selected_identifier, sd_active} = mode_focus(socket, grid, visible_agents)

    socket
    |> assign(:deck_nav, nav)
    |> assign(:grid, grid)
    |> assign(:usage, usage)
    |> assign(:grid_page, page)
    |> assign(:grid_column_offset, column_offset)
    |> assign(:grid_dial_value, dial_value)
    |> assign(:selected_identifier, selected_identifier)
    |> assign(:sd_active, sd_active)
    |> assign(:sd_ticket, if(sd_active, do: TicketPage.read(to_string(sd_active.identifier))))
    |> refresh_knobs()
  end

  @spec assign_grid_dial(Socket.t(), number()) :: Socket.t()
  def assign_grid_dial(socket, value),
    do: assign_grid(socket, socket.assigns.grid, 0, nil, clamp(value, 0, 100))

  @spec assign_grid_window(Socket.t(), integer()) :: Socket.t()
  def assign_grid_window(socket, page) do
    page = clamp_page(page, socket.assigns.grid.windows)
    column_offset = min(page * 4, max_column_offset(socket.assigns.grid.total))
    dial_value = dial_value_from_offset(column_offset, socket.assigns.grid.total)
    assign_grid(socket, socket.assigns.grid, column_offset, nil, dial_value)
  end

  defp selected_identifier(socket, grid, visible_agents) do
    current = socket.assigns[:selected_identifier]
    identifiers = Enum.map(grid.agents, &to_string(&1.identifier))

    cond do
      is_binary(current) and current in identifiers -> current
      visible_agents != [] -> to_string(hd(visible_agents).identifier)
      true -> nil
    end
  end

  defp mode_focus(%{assigns: %{sd_mode: mode, sd_active: active}}, grid, _visible_agents)
       when mode in [:cmd, :settings] and not is_nil(active) do
    identifier = to_string(active.identifier)
    refreshed_active = Enum.find(grid.agents, active, &(to_string(&1.identifier) == identifier))
    {identifier, refreshed_active}
  end

  defp mode_focus(socket, grid, visible_agents) do
    {selected_identifier(socket, grid, visible_agents), socket.assigns.sd_active}
  end

  defp load_grid, do: StreamdeckFleet.grid(nil)

  @spec refresh_knobs(Socket.t()) :: Socket.t()
  def refresh_knobs(socket) do
    assign(
      socket,
      :knobs,
      knob_descriptors(
        socket.assigns.grid_dial_value,
        socket.assigns.grid.windows,
        socket.assigns.sd_mode
      )
    )
  end

  @spec replace_transcript_relay(Socket.t(), String.t() | nil, String.t() | nil) :: Socket.t()
  def replace_transcript_relay(socket, previous_identifier, identifier) do
    if previous_identifier != identifier and is_pid(socket.assigns[:transcript_relay]) do
      _ = GenServer.stop(socket.assigns.transcript_relay, :normal)
    end

    relay =
      if connected?(socket) and is_binary(identifier) and previous_identifier != identifier do
        {:ok, relay} =
          StreamdeckTranscriptRelay.start_link(self(), identifier, transcript_flush_ms())

        relay
      else
        socket.assigns[:transcript_relay]
      end

    assign(socket, :transcript_relay, relay)
  end

  @spec focus_agent(Socket.t(), String.t() | nil, String.t() | nil) :: Socket.t()
  def focus_agent(socket, previous_identifier, identifier)
      when previous_identifier != identifier do
    socket
    |> replace_transcript_relay(previous_identifier, identifier)
    |> refresh_knobs()
  end

  def focus_agent(socket, _previous_identifier, _identifier), do: socket

  defp transcript_flush_ms do
    EndpointConfig.get(:streamdeck_transcript_flush_ms) ||
      Application.get_env(:aiur, Endpoint, []) |> Keyword.get(:streamdeck_transcript_flush_ms) ||
      250
  end
end
