defmodule AiurWeb.StreamdeckLive do
  @moduledoc """
  Browser emulator for the Stream Deck control surface.

  The view renders the same orchestrator snapshot projection used by the
  Stream Deck API and subscribes to the fleet topics so browser state follows
  the dashboard. Key presses use the existing AgentChat control facade; the
  orchestrator remains the authority for the resulting pause/resume state.
  """

  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias Aiur.{AgentChat, AgentPubSub, Orchestrator}
  alias Aiur.ProviderMeters.Events, as: ProviderMeterEvents
  alias AiurWeb.OperatorControlCenter.{DashboardShell, NavState, RouteRegistry}
  alias AiurWeb.{Endpoint, StreamDeckGrid, StreamdeckProjection}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> NavState.assign_nav()
      |> assign(:current_route, RouteRegistry.current_route(:streamdeck))
      |> assign(:knobs, knob_descriptors())
      |> assign(:grid_page, 0)
      |> assign(:grid_column_offset, 0)
      |> assign(:grid_dial_value, 0)
      |> assign(:logs, load_logs())
      |> assign(:control_feedback, nil)
      |> assign(:tracker_kind, kind(&Aiur.Config.tracker_kind/0, "tracker unavailable"))
      |> assign(:agent_kind, kind(&Aiur.Config.agent_kind/0, "agent unavailable"))
      |> refresh_grid()

    if connected?(socket) do
      :ok = AgentPubSub.subscribe_running()
      :ok = AgentPubSub.subscribe_status()
      :ok = ProviderMeterEvents.subscribe_observed()
      maybe_subscribe_fixture_fleet()
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle-nav", _params, socket), do: {:noreply, NavState.toggle(socket)}

  def handle_event("restore-nav", %{"collapsed" => collapsed}, socket),
    do: {:noreply, NavState.restore(socket, collapsed)}

  def handle_event("grid-page", %{"page" => page}, socket) do
    page = parse_integer(page, socket.assigns.grid_page)
    previous_identifier = socket.assigns.selected_identifier
    socket = assign_grid_window(socket, page)
    maybe_resubscribe_agent(previous_identifier, socket.assigns.selected_identifier)
    {:noreply, socket}
  end

  def handle_event("grid-page", %{"value" => value}, socket) do
    value = parse_integer(value, socket.assigns.grid_dial_value)
    previous_identifier = socket.assigns.selected_identifier
    socket = assign_grid_dial(socket, value)
    maybe_resubscribe_agent(previous_identifier, socket.assigns.selected_identifier)
    {:noreply, socket}
  end

  def handle_event("grid-page", %{"action" => "cycle"}, socket) do
    page = rem(socket.assigns.grid_page + 1, max(socket.assigns.grid.windows, 1))
    previous_identifier = socket.assigns.selected_identifier
    socket = assign_grid_window(socket, page)
    maybe_resubscribe_agent(previous_identifier, socket.assigns.selected_identifier)
    {:noreply, socket}
  end

  def handle_event("logs-scroll", %{"axis" => axis, "delta" => delta}, socket)
      when axis in ["events", "transcript"] do
    {:noreply, update_logs(socket, axis, parse_integer(delta, 0))}
  end

  def handle_event("key-press", params, socket) do
    socket = select_agent_from_params(socket, params)

    if dashboard_writable?() do
      handle_key_press(params, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("dial-press", %{"index" => _index, "action" => _action}, socket),
    do: {:noreply, socket}

  def handle_event("mic-hold", %{"active" => _active}, socket),
    do: {:noreply, socket}

  @impl true
  def handle_info({:running_changed, _summaries}, socket) do
    socket = refresh_grid(socket)
    {:noreply, assign(socket, :logs, append_log_event(socket.assigns.logs, "Fleet running state updated"))}
  end

  def handle_info({:status_changed, %{identifier: identifier}}, socket) do
    socket = refresh_grid(socket)
    {:noreply, assign(socket, :logs, append_log_event(socket.assigns.logs, "Agent ##{identifier} status updated"))}
  end

  def handle_info(:streamdeck_fixture_fleet_changed, socket) do
    {:noreply, refresh_grid(socket)}
  end

  def handle_info({:provider_meter_changed, _snapshot}, socket) do
    socket = refresh_grid(socket)
    {:noreply, assign(socket, :logs, append_log_event(socket.assigns.logs, "Provider usage updated"))}
  end

  def handle_info({:transcript_event, event}, socket) when is_map(event) do
    {:noreply, assign(socket, :logs, append_transcript(socket.assigns.logs, event))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <DashboardShell.dashboard_shell
      route={@current_route}
      routes={RouteRegistry.routes(%{})}
      tracker_kind={@tracker_kind}
      agent_kind={@agent_kind}
      nav_collapsed={@nav_collapsed}
    >
      <section id="streamdeck-page" class="sd-stage" aria-label="Stream Deck emulator" phx-hook="StreamdeckEmulator">
        <div class="sd-device" role="group" aria-label="Stream Deck + control surface" data-mode="grid">
          <header class="sd-brand">
            <span class="sd-brand-mark" aria-hidden="true"><i></i><i></i><i></i><i></i></span>
            <span>STREAM DECK</span>
          </header>

          <ul id="sd-keys" class="sd-keys" data-mode-view="grid" aria-label="Agent keys" data-grid-total={@grid.total} data-grid-windows={@grid.windows} data-grid-page={@grid_page} data-grid-page-count={@grid.windows} data-grid-column-offset={@grid_column_offset} data-grid-dial-value={@grid_dial_value} data-grid-selected-identifier={@selected_identifier}>
            <li
              :for={key <- @keys}
              class={["sd-key", key.empty? && "is-empty", "st-#{key.bucket}"]}
              aria-hidden={to_string(key.empty?)}
              data-streamdeck-key={key.slot}
              data-streamdeck-identifier={key.identifier}
              data-control-action={key.control_action}
            >
              <div class="sd-key-face">
                <div :if={!key.empty?} class="sd-key-topline">
                  <span class="sd-key-vendor">{key.vendor}</span>
                  <span :if={key.priority?} class="sd-key-priority" aria-label="Priority">★</span>
                </div>
                <div :if={!key.empty?} class="sd-key-main">
                  <span class="sd-key-ticket">#{key.ticket}</span>
                  <span class="sd-key-title">{key.title}</span>
                </div>
                <div :if={!key.empty? and key.bucket == "queued"} class="sd-key-footer">
                  <span>{key.label}</span><b>{key.dependency}</b>
                </div>
                <div :if={!key.empty? and key.bucket != "queued"} class="sd-key-footer">
                  <span class="sd-status-dot" aria-hidden="true"></span><span>{key.label}</span>
                  <span class="sd-progress" role="progressbar" aria-valuenow={key.progress} aria-valuemin="0" aria-valuemax="100" aria-label={"#{key.progress}% complete"}><i style={"width: #{key.progress}%"}></i></span>
                </div>
              </div>
            </li>
          </ul>

          <div id="sd-pager-dots" class="sd-pager-dots" aria-label="Agent pages">
            <span
              :for={page <- pager_pages(@grid.windows)}
              class={if page == @grid_page, do: "is-active", else: nil}
              data-page={page}
              aria-current={if page == @grid_page, do: "page", else: nil}
            >•</span>
          </div>

          <div id="sd-cmd-view" class="sd-cmd-view" data-mode-view="cmd" role="group" aria-label="Agent commands" aria-hidden="true">
            <p class="sd-mode-label">Commands</p>
            <p id="sd-control-status" role="status" aria-live="polite">{control_feedback(@control_feedback)}</p>
            <ul class="sd-cmd-list" aria-label="Available commands">
              <li class="sd-cmd-item">Run tests</li>
              <li class="sd-cmd-item">Deploy staging</li>
              <li class="sd-cmd-item">View logs</li>
              <li class="sd-cmd-item">Open PR</li>
            </ul>
          </div>

          <div id="sd-logs-view" class="sd-logs-view" data-mode-view="logs" role="log" aria-label="Agent logs" aria-hidden="true">
            <p class="sd-mode-label">Logs</p>
            <div id="sd-log-events" class="sd-log-body" data-offset={@logs.events_offset} data-max-offset={@logs.events_max_offset}>
              <span id="sd-events-hint-up" class="sd-log-hint" aria-hidden={to_string(@logs.events_offset == 0)}>↑</span>
              <p :for={line <- @logs.events_visible} class="sd-log-line">{line}</p>
              <p :if={@logs.events_visible == []} class="sd-log-line">No recent events.</p>
              <span id="sd-events-hint-down" class="sd-log-hint" aria-hidden={to_string(@logs.events_offset >= @logs.events_max_offset)}>↓</span>
            </div>
            <div id="sd-log-transcript" class="sd-log-body" data-offset={@logs.transcript_offset} data-max-offset={@logs.transcript_max_offset}>
              <span id="sd-transcript-hint-up" class="sd-log-hint" aria-hidden={to_string(@logs.transcript_offset == 0)}>↑</span>
              <p :for={line <- @logs.transcript_visible} class="sd-log-line">{line}</p>
              <p :if={@logs.transcript_visible == []} class="sd-log-line">No recent transcript.</p>
              <span id="sd-transcript-hint-down" class="sd-log-hint" aria-hidden={to_string(@logs.transcript_offset >= @logs.transcript_max_offset)}>↓</span>
            </div>
          </div>

          <div id="sd-screen" class="sd-screen" role="group" aria-label="Touch strip">
            <div :for={segment <- @screen} class={["sd-screen-segment", segment.live? && "is-live"]}>
              <span :if={segment.label == "Claude"} class="sd-mic" aria-hidden="true"></span>
              <span class="sd-screen-icon" aria-hidden="true">{segment.icon}</span>
              <span>{segment.label}</span>
              <span :if={segment.value} class="sd-screen-value">{segment.value}</span>
            </div>
          </div>

          <div class="sd-well">
            <div id="sd-knobs" class="sd-knobs" role="group" aria-label="Control dials">
              <div :for={{knob, idx} <- Enum.with_index(@knobs)} class="sd-knob-wrap">
                <div
                  class="sd-knob"
                  style={"--a: #{knob.angle}deg; touch-action: none;"}
                  role="slider"
                  tabindex="0"
                  aria-label={knob_aria_label(knob, idx)}
                  aria-valuemin="0"
                  aria-valuemax="100"
                  aria-valuenow={knob.value}
                  data-value={knob.value}
                >
                  <span class="sd-knob-marker" aria-hidden="true"></span>
                  <span class="sd-knob-inner">{knob.value}</span>
                </div>
                <span aria-hidden="true">{knob.label}</span>
              </div>
            </div>
          </div>
        </div>
      </section>
    </DashboardShell.dashboard_shell>
    """
  end

  defp refresh_grid(socket) do
    grid = load_grid()
    usage = StreamdeckProjection.provider_meters()
    previous_identifier = socket.assigns[:selected_identifier]
    dial_value = socket.assigns[:grid_dial_value] || 0
    column_offset = column_offset_from_dial(dial_value, grid.total)
    socket = assign_grid(socket, grid, column_offset, usage, dial_value)

    if connected?(socket) do
      maybe_resubscribe_agent(previous_identifier, socket.assigns.selected_identifier)
    end

    socket
  end

  defp assign_grid(socket, grid, column_offset, usage, dial_value) do
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

    socket
    |> assign(:grid, grid)
    |> assign(:grid_page, page)
    |> assign(:grid_column_offset, column_offset)
    |> assign(:grid_dial_value, dial_value)
    |> assign(:selected_identifier, selected_identifier(socket, grid, visible_agents))
    |> assign(:keys, key_descriptors(grid.agents, column_offset))
    |> assign(:screen, screen_descriptors(grid, usage))
    |> assign(:knobs, knob_descriptors(dial_value, grid.windows))
  end

  defp assign_grid_dial(socket, value), do: assign_grid(socket, socket.assigns.grid, 0, nil, clamp(value, 0, 100))

  defp assign_grid_window(socket, page) do
    page = clamp_page(page, socket.assigns.grid.windows)
    column_offset = min(page * 4, max_column_offset(socket.assigns.grid.total))
    dial_value = dial_value_from_offset(column_offset, socket.assigns.grid.total)
    assign_grid(socket, socket.assigns.grid, column_offset, nil, dial_value)
  end

  defp key_descriptors(agents, column_offset) do
    for slot <- 0..7 do
      column = rem(slot, 4)
      row = div(slot, 4)

      case Enum.at(agents, (column_offset + column) * 2 + row) do
        nil -> empty_key(slot + 1)
        agent -> agent_key(slot + 1, agent)
      end
    end
  end

  defp agent_key(slot, agent) do
    bucket = Map.fetch!(agent, :bucket)
    dependency_ready = Map.get(agent, :dependency_ready, true)

    key(
      slot,
      Atom.to_string(bucket),
      Map.get(agent, :vendor, "unknown"),
      Map.get(agent, :identifier),
      Map.get(agent, :title, "Untitled"),
      bucket_label(bucket),
      Map.get(agent, :progress_percent, 0),
      identifier: Map.get(agent, :identifier),
      control_action: control_action(bucket),
      priority?: Map.get(agent, :priority, false),
      dependency: if(bucket == :queued and not dependency_ready, do: "Blocked")
    )
  end

  defp key(slot, bucket, vendor, ticket, title, label, progress, opts) do
    %{
      slot: slot,
      bucket: bucket,
      vendor: vendor,
      ticket: ticket,
      title: title,
      label: label,
      progress: progress,
      priority?: Keyword.get(opts, :priority?, false),
      dependency: Keyword.get(opts, :dependency),
      identifier: Keyword.get(opts, :identifier, ticket),
      control_action: Keyword.get(opts, :control_action),
      empty?: false
    }
  end

  defp empty_key(slot),
    do: %{slot: slot, bucket: "empty", identifier: nil, control_action: nil, empty?: true}

  defp screen_descriptors(grid, usage) do
    [
      %{label: "Summary", icon: "▤", live?: grid.total > 0, value: "#{grid.total} agents"},
      provider_segment("Claude", "claude", "◒", usage),
      provider_segment("Codex", "codex", "◇", usage),
      %{label: "Pager", icon: "›", live?: grid.windows > 1, value: "#{grid.windows} windows"}
    ]
  end

  defp provider_segment(label, provider, icon, usage) do
    meter = Map.get(usage, provider)
    %{label: label, icon: icon, live?: is_map(meter), value: provider_value(meter)}
  end

  defp provider_value(%{} = meter) do
    percentages =
      case get_value(meter, "windows") do
        windows when is_map(windows) ->
          windows
          |> Enum.map(fn {name, window} -> {name, window_percentage(window)} end)
          |> Enum.filter(fn {_name, percentage} -> is_integer(percentage) end)
          |> Enum.sort_by(fn {name, _percentage} -> to_string(name) end)

        _ ->
          []
      end

    case percentages do
      [_ | _] ->
        Enum.map_join(percentages, " · ", fn {name, percentage} -> "#{name} #{percentage}%" end)

      [] ->
        get_value(meter, "state", "observed") |> to_string()
    end
  end

  defp provider_value(_meter), do: "Unavailable"

  defp bucket_label(:alert), do: "Alert"
  defp bucket_label(:stuck), do: "Stuck"
  defp bucket_label(:running), do: "Running"
  defp bucket_label(:paused), do: "Paused"
  defp bucket_label(:queued), do: "Queued"

  defp control_action(:running), do: "pause"
  defp control_action(:paused), do: "resume"
  defp control_action(_bucket), do: nil

  defp invoke_agent_control(socket, identifier, :pause) do
    case safe_control_call(fn -> pause_agent(identifier) end) do
      {:ok, _request_id} ->
        assign(socket, :control_feedback, "Pause requested for ##{identifier}")

      {:error, reason} ->
        assign(socket, :control_feedback, "Pause failed: #{inspect(reason)}")
    end
  end

  defp invoke_agent_control(socket, identifier, :resume) do
    case safe_control_call(fn -> resume_agent(identifier) end) do
      {:ok, _result} -> assign(socket, :control_feedback, "Resume requested for ##{identifier}")
      {:error, reason} -> assign(socket, :control_feedback, "Resume failed: #{inspect(reason)}")
    end
  end

  defp handle_key_press(%{"identifier" => identifier}, socket) when is_binary(identifier) do
    case Enum.find(socket.assigns.grid.agents, &(to_string(&1.identifier) == identifier)) do
      %{bucket: bucket} when bucket in [:running, :paused] ->
        action = if bucket == :running, do: :pause, else: :resume
        {:noreply, invoke_agent_control(socket, identifier, action)}

      _agent ->
        {:noreply, socket}
    end
  end

  defp handle_key_press(_params, socket), do: {:noreply, socket}

  defp select_agent_from_params(socket, %{"identifier" => identifier}) when is_binary(identifier) do
    if Enum.any?(socket.assigns.grid.agents, &(to_string(&1.identifier) == identifier)) do
      previous_identifier = socket.assigns.selected_identifier
      socket = assign(socket, :selected_identifier, identifier)
      maybe_resubscribe_agent(previous_identifier, identifier)
      socket
    else
      socket
    end
  end

  defp select_agent_from_params(socket, _params), do: socket

  defp update_logs(socket, axis, delta) do
    logs = socket.assigns.logs
    offset_key = String.to_existing_atom("#{axis}_offset")
    max_key = String.to_existing_atom("#{axis}_max_offset")
    offset = clamp(Map.fetch!(logs, offset_key) + delta, 0, Map.fetch!(logs, max_key))
    assign(socket, :logs, logs |> Map.put(offset_key, offset) |> visible_logs())
  rescue
    _ -> socket
  end

  defp append_transcript(logs, event) do
    logs
    |> Map.update!(:transcript, &(&1 ++ [log_line(event)]))
    |> Map.put(:transcript_max_offset, max(length(logs.transcript) + 1 - 4, 0))
    |> visible_logs()
  end

  defp append_log_event(logs, line) do
    logs
    |> Map.update!(:events, &(&1 ++ [line]))
    |> Map.put(:events_max_offset, max(length(logs.events) + 1 - 4, 0))
    |> visible_logs()
  end

  defp visible_logs(logs) do
    logs
    |> Map.put(:events_visible, Enum.slice(logs.events, logs.events_offset, 4))
    |> Map.put(:transcript_visible, Enum.slice(logs.transcript, logs.transcript_offset, 4))
  end

  defp load_logs do
    raw =
      case endpoint_config(:streamdeck_logs_fun) do
        fun when is_function(fun, 0) -> safe_call(fun, %{})
        _ -> %{}
      end

    events = raw |> get_value("events", []) |> Enum.map(&log_line/1)
    transcript = raw |> get_value("transcript", []) |> Enum.map(&log_line/1)

    %{
      events: events,
      transcript: transcript,
      events_offset: 0,
      events_max_offset: max(length(events) - 4, 0),
      transcript_offset: 0,
      transcript_max_offset: max(length(transcript) - 4, 0)
    }
    |> visible_logs()
  end

  defp log_line(%{} = event) do
    role = get_value(event, "role")
    body = get_value(event, "body", get_value(event, "message", ""))
    "[#{role || "event"}] #{body}"
  end

  defp log_line(line), do: to_string(line)

  defp maybe_subscribe_agent(identifier) when is_binary(identifier) do
    _ = AgentPubSub.subscribe_agent(identifier)
    :ok
  end

  defp maybe_subscribe_agent(_identifier), do: :ok

  defp maybe_subscribe_fixture_fleet do
    if endpoint_config(:streamdeck_fixture_fleet) do
      Phoenix.PubSub.subscribe(Aiur.PubSub, "streamdeck:fixture")
    end

    :ok
  end

  defp maybe_resubscribe_agent(previous, current) when previous == current, do: :ok

  defp maybe_resubscribe_agent(previous, current) do
    if is_binary(previous), do: AgentPubSub.unsubscribe_agent(previous)
    maybe_subscribe_agent(current)
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

  defp clamp_page(page, windows) when is_integer(page), do: clamp(page, 0, max(windows - 1, 0))
  defp clamp_page(_page, windows), do: clamp_page(0, windows)

  defp max_column_offset(agent_count), do: max(0, ceil(agent_count / 2) - 4)
  defp clamp_column_offset(offset, agent_count), do: clamp(offset, 0, max_column_offset(agent_count))
  defp column_offset_from_dial(value, agent_count), do: round(clamp(value, 0, 100) / 100 * max_column_offset(agent_count))

  defp dial_value_from_offset(offset, agent_count) do
    max_offset = max_column_offset(agent_count)
    if max_offset == 0, do: 0, else: clamp(round(offset / max_offset * 100), 0, 100)
  end

  defp current_window(column_offset, agent_count) do
    max_offset = max_column_offset(agent_count)
    windows = max(1, ceil(agent_count / 8))

    if column_offset >= max_offset,
      do: windows - 1,
      else: min(div(max(column_offset, 0), 4), windows - 1)
  end

  defp pager_pages(0), do: []
  defp pager_pages(windows), do: 0..(windows - 1)

  defp parse_integer(value, _fallback) when is_integer(value), do: value

  defp parse_integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> fallback
    end
  end

  defp parse_integer(_value, fallback), do: fallback

  defp clamp(value, min, max), do: value |> max(min) |> min(max)

  defp get_value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key), default))
  rescue
    _ -> Map.get(map, key, default)
  end

  defp window_percentage(window) when is_map(window) do
    used_percent = get_value(window, "used_percent")
    used = get_value(window, "used")
    limit = get_value(window, "limit")

    cond do
      is_number(used_percent) -> round(used_percent)
      is_number(used) and is_number(limit) and limit > 0 -> round(used / limit * 100)
      true -> nil
    end
  end

  defp window_percentage(_window), do: nil

  defp pause_agent(identifier) do
    case endpoint_config(:agent_chat_pause_fun) do
      fun when is_function(fun, 1) -> fun.(identifier)
      _fun -> AgentChat.pause(identifier)
    end
  end

  defp resume_agent(identifier) do
    case endpoint_config(:agent_chat_resume_fun) do
      fun when is_function(fun, 1) -> fun.(identifier)
      _fun -> AgentChat.resume(identifier)
    end
  end

  defp safe_control_call(fun) do
    fun.()
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp control_feedback(nil), do: ""
  defp control_feedback(feedback), do: feedback

  defp load_grid do
    snapshot_fun = endpoint_config(:streamdeck_snapshot_fun)

    snapshot =
      case snapshot_fun do
        fun when is_function(fun, 0) ->
          safe_call(fun, %{})

        _ ->
          safe_call(fn -> Orchestrator.snapshot(orchestrator(), snapshot_timeout_ms()) end, %{})
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
  defp snapshot_timeout_ms, do: endpoint_config(:snapshot_timeout_ms) || 15_000

  defp safe_call(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    :exit, _ -> fallback
  end

  defp endpoint_config(key) do
    Endpoint.config(key) || Application.get_env(:aiur, Endpoint, []) |> Keyword.get(key)
  rescue
    _ -> Application.get_env(:aiur, Endpoint, []) |> Keyword.get(key)
  end

  defp dashboard_writable? do
    Endpoint.config(:dashboard_writable) == true
  rescue
    _ -> false
  end

  defp knob_descriptors(dial_value \\ 0, windows \\ 0) do
    [
      %{label: "Focus", value: "62", angle: 138},
      %{label: "Volume", value: "74", angle: 174},
      %{label: "Speed", value: "48", angle: 78},
      %{
        label: "Page",
        value: String.pad_leading(to_string(dial_value), 2, "0"),
        angle: if(windows > 0, do: dial_value / 100 * 270 - 135, else: -135)
      }
    ]
  end

  # Dial 0 presses BACK, dial 3 cycles the focused window. Labels convey this.
  defp knob_aria_label(%{label: label, value: value}, 0),
    do: "#{label}: #{value} — press to go back"

  defp knob_aria_label(%{label: label, value: value}, 3),
    do: "#{label}: #{value} — press to cycle window"

  defp knob_aria_label(%{label: label, value: value}, _),
    do: "#{label}: #{value}"

  defp kind(provider, fallback) do
    case provider.() do
      value when is_atom(value) or is_binary(value) -> to_string(value)
      _ -> fallback
    end
  rescue
    _ -> fallback
  end
end
