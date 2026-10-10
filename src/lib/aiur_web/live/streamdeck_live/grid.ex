defmodule AiurWeb.StreamdeckLive.Grid do
  @moduledoc """
  Socket state for the Stream Deck emulator's fleet grid: loading the
  orchestrator snapshot, windowing it under the page dial, keeping the focused
  agent, and loading that agent's logs and transcript relay. Socket in, socket
  out.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]
  import AiurWeb.StreamdeckLive.Env, only: [endpoint_config: 1, safe_call: 2]
  import AiurWeb.StreamdeckLive.Surface

  alias Aiur.{Conversation.History, Orchestrator, PollCadence}
  alias AiurWeb.{Endpoint, StreamDeckGrid, StreamdeckLogs, StreamdeckProjection, StreamdeckTranscriptRelay}
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
      focus_logs(socket, previous_identifier, socket.assigns.selected_identifier)
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
    screen = screen_descriptors(socket.assigns.grid, usage, socket.assigns.grid_page, mode_pager_focus(socket.assigns.sd_mode, socket.assigns.sd_active))
    assign(socket, :screen, screen)
  end

  @spec assign_grid(Socket.t(), map(), integer(), map() | nil, number() | nil) :: Socket.t()
  def assign_grid(socket, grid, column_offset, usage, dial_value) do
    {dial_value, column_offset} =
      case dial_value do
        nil ->
          {dial_value_from_offset(column_offset, grid.total), clamp_column_offset(column_offset, grid.total)}

        value ->
          value = clamp(value, 0, 100)
          {value, column_offset_from_dial(value, grid.total)}
      end

    page = current_window(column_offset, grid.total)
    usage = usage || StreamdeckProjection.provider_meters()
    visible_agents = Enum.slice(grid.agents, column_offset * grid.rows_per_column, grid.agents_per_page)
    {selected_identifier, sd_active} = mode_focus(socket, grid, visible_agents)

    socket
    |> assign(:grid, grid)
    |> assign(:grid_page, page)
    |> assign(:grid_column_offset, column_offset)
    |> assign(:grid_dial_value, dial_value)
    |> assign(:selected_identifier, selected_identifier)
    |> assign(:sd_active, sd_active)
    |> assign(:keys, key_descriptors(grid.agents, column_offset))
    |> assign(:screen, screen_descriptors(grid, usage, page, mode_pager_focus(socket.assigns.sd_mode, sd_active)))
    |> refresh_knobs()
  end

  @spec assign_grid_dial(Socket.t(), number()) :: Socket.t()
  def assign_grid_dial(socket, value), do: assign_grid(socket, socket.assigns.grid, 0, nil, clamp(value, 0, 100))

  @spec assign_grid_window(Socket.t(), integer()) :: Socket.t()
  def assign_grid_window(socket, page) do
    page = clamp_page(page, socket.assigns.grid.windows)
    column_offset = min(page * 4, max_column_offset(socket.assigns.grid.total))
    dial_value = dial_value_from_offset(column_offset, socket.assigns.grid.total)
    assign_grid(socket, socket.assigns.grid, column_offset, nil, dial_value)
  end

  defp pager_focus(%{assigns: %{sd_mode: mode, sd_active: active}}), do: mode_pager_focus(mode, active)

  @spec refresh_pager(Socket.t()) :: Socket.t()
  def refresh_pager(socket) do
    focus = pager_focus(socket)

    screen =
      Enum.map(socket.assigns.screen, fn
        %{kind: :pager} = segment -> pager_segment(socket.assigns.grid, segment.current_page, focus)
        segment -> segment
      end)

    assign(socket, :screen, screen)
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
       when mode in [:cmd, :logs, :settings] and not is_nil(active) do
    identifier = to_string(active.identifier)
    refreshed_active = Enum.find(grid.agents, active, &(to_string(&1.identifier) == identifier))
    {identifier, refreshed_active}
  end

  defp mode_focus(socket, grid, visible_agents) do
    {selected_identifier(socket, grid, visible_agents), socket.assigns.sd_active}
  end

  @spec update_logs(Socket.t(), String.t(), integer()) :: Socket.t()
  def update_logs(socket, axis, delta) do
    axis = String.to_existing_atom(axis)
    socket |> assign(:logs, StreamdeckLogs.scroll(socket.assigns.logs, axis, delta)) |> refresh_knobs()
  rescue
    _ -> socket
  end

  @spec load_logs(term()) :: map()
  def load_logs(identifier) when is_binary(identifier) do
    identifier |> load_log_entries() |> StreamdeckLogs.project()
  end

  def load_logs(_identifier), do: StreamdeckLogs.project([])

  @spec reload_logs(Socket.t(), String.t()) :: Socket.t()
  def reload_logs(socket, identifier) do
    logs = StreamdeckLogs.refresh(socket.assigns.logs, load_log_entries(identifier))
    socket |> assign(:logs, logs) |> refresh_knobs()
  end

  defp load_log_entries(identifier) do
    case endpoint_config(:streamdeck_logs_fun) do
      fun when is_function(fun, 1) -> safe_call(fn -> fun.(identifier) end, [])
      fun when is_function(fun, 0) -> safe_call(fun, [])
      _ -> safe_call(fn -> agent_event_feed(identifier) end, [])
    end
    |> log_entries()
  end

  defp agent_event_feed(identifier) do
    transcript =
      case History.transcript(identifier, %{"limit" => 50}) do
        {:ok, %{events: events}} -> events
        _ -> []
      end

    %{events: History.bus_events(identifier), transcript: transcript}
  end

  # The emulator's injected feed function predates the bus/transcript split and
  # still hands back a bare transcript list. Normalise every accepted shape into
  # the two-source map the projection now takes, so a fixture written against
  # the old contract keeps working and simply projects with an empty bus.
  defp log_entries(%{events: events, transcript: transcript}) when is_list(events) and is_list(transcript),
    do: %{events: events, transcript: transcript}

  defp log_entries(%{events: events}) when is_list(events), do: %{events: [], transcript: events}
  defp log_entries(%{"events" => events}) when is_list(events), do: %{events: [], transcript: events}
  defp log_entries(entries) when is_list(entries), do: %{events: [], transcript: entries}
  defp log_entries(_entries), do: %{events: [], transcript: []}

  defp load_grid do
    snapshot =
      case endpoint_config(:streamdeck_snapshot_fun) do
        fun when is_function(fun, 0) ->
          safe_call(fun, %{})

        _ ->
          # Read the lock-free, coalesced dashboard snapshot rather than asking
          # the Orchestrator to build one synchronously. `refresh_grid/1` runs on
          # every fleet/status event; a blocking `Orchestrator.snapshot/2` call
          # there stalls the LiveView (and can wedge it under dispatch).
          case safe_call(fn -> Orchestrator.dashboard_snapshot(orchestrator(), snapshot_timeout_ms()) end, %{}) do
            {status, snapshot, _freshness} when status in [:current, :stale] and is_map(snapshot) -> snapshot
            snapshot when is_map(snapshot) -> snapshot
            _ -> %{}
          end
      end

    case snapshot do
      %{} = snapshot -> StreamDeckGrid.project(snapshot)
      _ -> empty_grid()
    end
  end

  defp empty_grid do
    %{
      agents: [],
      total: 0,
      columns_per_page: 4,
      rows_per_column: 2,
      agents_per_page: 8,
      windows: 0,
      max_column_offset: 0
    }
  end

  defp orchestrator, do: endpoint_config(:orchestrator) || Orchestrator
  # The configured value is the floor, not the tolerance: a fixed 15s window
  # against a 120s poll marks a healthy fleet stale for most of every cycle.
  # See `Aiur.PollCadence.snapshot_tolerance_ms/1`.
  defp snapshot_timeout_ms, do: PollCadence.snapshot_tolerance_ms(endpoint_config(:snapshot_timeout_ms) || 15_000, class: :dispatch)

  @spec refresh_knobs(Socket.t()) :: Socket.t()
  def refresh_knobs(socket) do
    assign(socket, :knobs, knob_descriptors(socket.assigns.grid_dial_value, socket.assigns.grid.windows, socket.assigns.sd_mode, socket.assigns.logs))
  end

  @spec replace_transcript_relay(Socket.t(), String.t() | nil, String.t() | nil) :: Socket.t()
  def replace_transcript_relay(socket, previous_identifier, identifier) do
    if previous_identifier != identifier and is_pid(socket.assigns[:transcript_relay]) do
      _ = GenServer.stop(socket.assigns.transcript_relay, :normal)
    end

    relay =
      if connected?(socket) and is_binary(identifier) and previous_identifier != identifier do
        {:ok, relay} = StreamdeckTranscriptRelay.start_link(self(), identifier, transcript_flush_ms())
        relay
      else
        socket.assigns[:transcript_relay]
      end

    assign(socket, :transcript_relay, relay)
  end

  @spec focus_logs(Socket.t(), String.t() | nil, String.t() | nil) :: Socket.t()
  def focus_logs(socket, previous_identifier, identifier) when previous_identifier != identifier do
    socket
    |> assign(:logs, load_logs(identifier))
    |> replace_transcript_relay(previous_identifier, identifier)
    |> refresh_knobs()
  end

  def focus_logs(socket, _previous_identifier, _identifier), do: socket

  defp transcript_flush_ms do
    Endpoint.config(:streamdeck_transcript_flush_ms) ||
      Application.get_env(:aiur, Endpoint, []) |> Keyword.get(:streamdeck_transcript_flush_ms) || 250
  end
end
