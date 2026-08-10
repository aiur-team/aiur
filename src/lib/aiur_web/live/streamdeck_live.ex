defmodule AiurWeb.StreamdeckLive do
  @moduledoc """
  Browser emulator for the Stream Deck control surface.

  The view renders the same orchestrator snapshot projection used by the
  Stream Deck API and subscribes to the fleet topics so browser state follows
  the dashboard. Key presses use the existing AgentChat control facade; the
  orchestrator remains the authority for the resulting pause/resume state.

  Logs mode subscribes the focused agent through `StreamdeckTranscriptRelay`
  and projects the durable classified feed (`AgentEventFeed`) through the
  flattened two-line model in `StreamdeckLogs`. The production path reads the
  real feed; `streamdeck_logs_fun` exists only as a test seam.
  """

  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias Aiur.{AgentChat, AgentEventFeed, AgentPubSub, CodingAgent, Orchestrator}
  alias Aiur.ProviderMeters.Events, as: ProviderMeterEvents
  alias AiurWeb.{Endpoint, StreamDeckGrid, StreamdeckLogs, StreamdeckProjection, StreamdeckTranscriptRelay}
  alias AiurWeb.OperatorControlCenter.{DashboardShell, NavState, RouteRegistry}

  @streamdeck_package %{
    version: "0.0.0-dev.0098e3ac86a2",
    commit: "0098e3ac86a2e49e685e8e6ff67248373de43f1d",
    url:
      "https://github.com/aiur-team/aiur/releases/download/streamdeck-0098e3ac86a2e49e685e8e6ff67248373de43f1d/" <>
        "aiur-streamdeck-0.0.0-dev.0098e3ac86a2-linux-x64-c6d1f373b30d8f038538becd746acb43ea2d4364501dc7ced4e65819e9bc76c3.tar.gz"
  }

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
      |> assign(:sd_mode, :grid)
      |> assign(:sd_active, nil)
      |> assign(:transcript_relay, nil)
      |> assign(:logs, StreamdeckLogs.project([]))
      |> assign(:control_feedback, nil)
      |> assign(:install_modal?, false)
      |> assign(:streamdeck_package, @streamdeck_package)
      |> assign(:mic_held?, false)
      |> assign(:tracker_kind, kind(&Aiur.Config.tracker_kind/0, "tracker unavailable"))
      |> assign(:agent_kind, kind(&Aiur.Config.agent_kind/0, "agent unavailable"))
      |> refresh_grid()

    socket = assign(socket, :logs, load_logs(socket.assigns.selected_identifier))

    socket =
      if connected?(socket) do
        :ok = AgentPubSub.subscribe_running()
        :ok = AgentPubSub.subscribe_status()
        :ok = ProviderMeterEvents.subscribe_observed()
        maybe_subscribe_fixture_fleet()
        replace_transcript_relay(socket, nil, socket.assigns.selected_identifier)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle-nav", _params, socket), do: {:noreply, NavState.toggle(socket)}

  def handle_event("restore-nav", %{"collapsed" => collapsed}, socket),
    do: {:noreply, NavState.restore(socket, collapsed)}

  def handle_event("open-streamdeck-install", _params, socket), do: {:noreply, assign(socket, :install_modal?, true)}

  def handle_event("close-streamdeck-install", _params, socket), do: {:noreply, assign(socket, :install_modal?, false)}

  def handle_event("grid-page", %{"page" => page}, socket) do
    page = parse_integer(page, socket.assigns.grid_page)
    previous_identifier = socket.assigns.selected_identifier
    socket = assign_grid_window(socket, page)
    socket = focus_logs(socket, previous_identifier, socket.assigns.selected_identifier)
    {:noreply, socket}
  end

  def handle_event("grid-page", %{"value" => value}, socket) do
    value = parse_integer(value, socket.assigns.grid_dial_value)
    previous_identifier = socket.assigns.selected_identifier
    socket = assign_grid_dial(socket, value)
    socket = focus_logs(socket, previous_identifier, socket.assigns.selected_identifier)
    {:noreply, socket}
  end

  def handle_event("grid-page", %{"action" => "cycle"}, socket) do
    page = rem(socket.assigns.grid_page + 1, max(socket.assigns.grid.windows, 1))
    previous_identifier = socket.assigns.selected_identifier
    socket = assign_grid_window(socket, page)
    socket = focus_logs(socket, previous_identifier, socket.assigns.selected_identifier)
    {:noreply, socket}
  end

  def handle_event("logs-scroll", %{"axis" => axis, "delta" => delta}, socket)
      when axis in ["events", "transcript"] do
    {:noreply, update_logs(socket, axis, parse_integer(delta, 0))}
  end

  def handle_event("key-press", params, socket) do
    socket = select_agent_from_params(socket, params)
    socket = enter_cmd(socket, params)

    if dashboard_writable?() do
      handle_key_press(params, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("command-press", %{"command" => "logs"}, socket), do: {:noreply, enter_logs(socket)}

  def handle_event("dial-press", %{"action" => "back"}, socket), do: {:noreply, back(socket)}

  def handle_event("dial-press", %{"action" => "cycle-window"}, socket),
    do: {:noreply, enter_logs(socket)}

  def handle_event("dial-press", %{"index" => _index, "action" => _action}, socket), do: {:noreply, socket}

  def handle_event("command-press", %{"command" => command}, socket) when command in ["pause", "priority", "logs"] do
    {:noreply, assign(socket, :control_feedback, "#{command_label(command)} selected")}
  end

  def handle_event("mic-hold", %{"active" => active}, socket) when is_boolean(active),
    do: {:noreply, assign(socket, :mic_held?, active)}

  def handle_event("mic-hold", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:running_changed, _summaries}, socket) do
    {:noreply, refresh_grid(socket)}
  end

  def handle_info({:status_changed, %{identifier: _identifier}}, socket) do
    {:noreply, refresh_grid(socket)}
  end

  def handle_info(:streamdeck_fixture_fleet_changed, socket) do
    {:noreply, refresh_grid(socket)}
  end

  def handle_info({:provider_meter_changed, _snapshot}, socket) do
    {:noreply, refresh_grid(socket)}
  end

  def handle_info({:streamdeck_transcript, identifier, _event}, socket) when is_binary(identifier) do
    if socket.assigns.selected_identifier == identifier do
      {:noreply, assign(socket, :logs, load_logs(identifier))}
    else
      {:noreply, socket}
    end
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
        <div class="sd-device" role="group" aria-label="Stream Deck + control surface" data-mode={@sd_mode}>
          <header class="sd-brand">
            <svg class="sd-brand-logo" viewBox="0 0 24 24" fill="none" aria-hidden="true">
              <circle cx="12" cy="12" r="9" stroke="#fff" stroke-width="2" />
              <path d="M15 12a3 3 0 1 0-3 3" stroke="#fff" stroke-width="2" fill="none" />
              <circle cx="12" cy="12" r="2" fill="#fff" />
            </svg>
            <span class="sd-brand-name">STREAM DECK</span>
            <div class="sd-package-controls">
              <a
                id="streamdeck-download-control"
                class="sd-install-control"
                href={@streamdeck_package.url}
                download
              >
                Download
              </a>
              <button id="streamdeck-install-control" class="sd-install-control" type="button" phx-click="open-streamdeck-install">
                Install +
              </button>
            </div>
          </header>

          <%= if @sd_mode == :grid do %>
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

          <% end %>

          <%= if @sd_mode == :cmd do %>
          <p id="sd-control-status" class="sr-only" role="status" aria-live="polite">{control_feedback(@control_feedback)}</p>
          <ul id="sd-keys" class="sd-keys sd-cmd-keys" data-mode-view="cmd" aria-label="Available commands">
            <li :for={key <- command_keys(@sd_active)} class={["sd-key", "sd-cmd-key", key.mic? && "sd-mic-key", key.mic? && @mic_held? && "mic-live", key.empty? && "is-empty"]} aria-hidden={to_string(key.empty?)}>
              <button :if={!key.empty?} type="button" class="sd-key-face" data-streamdeck-command={key.command} data-streamdeck-identifier={@selected_identifier} aria-label={key.label}>
                <span class="sd-cmd">
                  <span class="sd-cmd-ic" aria-hidden="true">
                    <svg :if={key.icon == "pause"} data-streamdeck-icon="pause" viewBox="0 0 24 24" fill="currentColor" stroke="none"><rect x="6.5" y="5" width="3.6" height="14" rx="1"/><rect x="13.9" y="5" width="3.6" height="14" rx="1"/></svg>
                    <svg :if={key.icon == "play"} data-streamdeck-icon="play" viewBox="0 0 24 24" fill="currentColor" stroke="none"><path d="M8 5.5v13l11-6.5z"/></svg>
                    <svg :if={key.icon == "up"} data-streamdeck-icon="up" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><path d="M12 19V5M6 11l6-6 6 6"/></svg>
                    <svg :if={key.icon == "down"} data-streamdeck-icon="down" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><path d="M12 5v14M6 13l6 6 6-6"/></svg>
                    <svg :if={key.icon == "logs"} data-streamdeck-icon="logs" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 6h16M4 12h16M4 18h10"/></svg>
                    <svg :if={key.icon == "mic"} data-streamdeck-icon="mic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M6 11a6 6 0 0 0 12 0M12 17v4"/></svg>
                  </span>
                  <span class="sd-cmd-label">{key.label}</span>
                  <span class="sd-cmd-sub">{key.sub}</span>
                </span>
              </button>
              <button :if={key.empty?} type="button" class="sd-key-face" disabled aria-hidden="true" tabindex="-1"></button>
            </li>
          </ul>
          <% end %>

          <%= if @sd_mode == :logs do %>
          <div id="sd-logs-view" class="sd-logs-view" data-mode-view="logs" data-focused-identifier={@sd_active.identifier} role="log" aria-label="Agent logs">
            <p class="sd-mode-label">Logs</p>
            <div id="sd-log-events" class="sd-log-body" data-offset={@logs.events_offset} data-max-offset={@logs.events_max_offset}>
              <span id="sd-events-hint-up" class="sd-log-hint" aria-hidden={to_string(@logs.events_offset == 0)}>↑</span>
              <p :for={event <- @logs.events_visible} class="sd-log-line">{StreamdeckLogs.line(%{kind: :event_header, badge: event.badge, body: event.body})}</p>
              <p :if={@logs.events_visible == []} class="sd-log-line">No recent events.</p>
              <span id="sd-events-hint-down" class="sd-log-hint" aria-hidden={to_string(@logs.events_offset >= @logs.events_max_offset)}>↓</span>
            </div>
            <div id="sd-log-transcript" class="sd-log-body" data-offset={@logs.transcript_offset} data-max-offset={@logs.transcript_max_offset}>
              <span id="sd-transcript-hint-up" class="sd-log-hint" aria-hidden={to_string(@logs.transcript_offset == 0)}>↑</span>
              <p :for={entry <- @logs.transcript_visible} class="sd-log-line" data-log-kind={entry.kind}>{StreamdeckLogs.line(entry)}</p>
              <p :if={@logs.transcript_visible == []} class="sd-log-line">No recent transcript.</p>
              <span id="sd-transcript-hint-down" class="sd-log-hint" aria-hidden={to_string(@logs.transcript_offset >= @logs.transcript_max_offset)}>↓</span>
            </div>
          </div>
          <% end %>

          <div id="sd-screen" class="sd-screen" style={"--sd-screen-segments: #{length(@screen)}"} role="group" aria-label="Touch strip">
            <div
              :for={segment <- @screen}
              class={[
                "sd-screen-segment",
                "sd-seg",
                if(segment.kind == :pager, do: "sd-seg-d", else: "sd-seg-info"),
                segment.observed? && "is-live"
              ]}
              data-segment={segment.kind}
            >
              <span :if={segment.kind == :pager} class="sd-seg-dlabel">{segment.label}</span>

              <div :if={segment.kind != :pager} class="sd-info-hd">
                <img class="sd-hd-logo" src={segment.logo} alt="" aria-hidden="true" />
                <span>{segment.label}</span>
                <span :if={segment.kind == :provider and segment.provider == "claude"} class="sd-mic" aria-hidden="true"></span>
              </div>

              <div :if={segment.kind == :summary} class="sd-info-live">
                <b>{segment.live}</b> live · <b>{segment.remaining}</b> left
              </div>

              <div :if={segment.kind == :summary} class="sd-mini" data-meter="build" data-observed="false">
                <span class="sd-mini-top">
                  <span class="sd-mini-lbl">Build</span>
                  <span class="sd-mini-r"></span>
                </span>
                <span class="sd-mini-bar" role="img" aria-label="Build progress unavailable"><i></i></span>
              </div>

              <div
                :for={meter <- segment.meters}
                :if={segment.kind == :provider}
                class={["sd-mini", meter.observed? && "is-observed", meter.stale? && "is-stale"]}
                data-provider={segment.provider}
                data-meter={meter.key}
                data-percent={meter.percent}
                data-observed={to_string(meter.observed?)}
                data-freshness={meter.freshness}
              >
                <span class="sd-mini-top">
                  <span class="sd-mini-lbl">{meter.label}</span>
                  <span :if={meter.observed?} class="sd-mini-r">{meter.percent}%<span :if={meter.metadata}> · {meter.metadata}</span></span>
                  <span :if={!meter.observed?} class="sd-mini-r"></span>
                </span>
                <span class="sd-mini-bar" role="img" aria-label={meter_aria_label(meter)}><i :if={meter.observed?} style={"width: #{meter.percent}%"}></i></span>
              </div>

              <div :if={segment.kind == :pager} class="sd-pager" role="group" aria-label={if segment.focus_label, do: "Controlled agent", else: "Agent pages"}>
                <span
                  :for={page <- segment.pages}
                  class={["sd-pager-dot", page == segment.current_page && "is-active"]}
                  data-pager-page={page}
                  aria-current={if page == segment.current_page, do: "page", else: nil}
                ></span>
                <span :if={segment.focus_label} class="sd-pager-label" data-pager-focus={segment.focus_label}>{segment.focus_label}</span>
              </div>
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

      <div :if={@install_modal?} class="modal-backdrop sd-install-backdrop">
        <section
          id="streamdeck-install-modal"
          class="modal-panel sd-install-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby="streamdeck-install-title"
          phx-click-away="close-streamdeck-install"
          phx-hook="TicketContextDialog"
          data-close-event="close-streamdeck-install"
          data-origin-id="streamdeck-install-control"
        >
          <header class="modal-header">
            <div>
              <p class="section-eyebrow">Stream Deck + sidecar</p>
              <h2 id="streamdeck-install-title" tabindex="-1" data-dialog-heading>Install on your Stream Deck +</h2>
            </div>
            <button type="button" class="tool-btn" phx-click="close-streamdeck-install">Close</button>
          </header>

          <p class="sd-install-intro">
            You need a Stream Deck +, Linux with udev, and a running Aiur daemon that the deck can reach.
          </p>

          <section class="sd-install-pairing" aria-labelledby="streamdeck-pairing-title">
            <h3 id="streamdeck-pairing-title">Pair it with your daemon</h3>
            <p>
              Put the daemon address and the dashboard’s HTTP Basic Auth username and password in
              <code>~/.config/aiur/streamdeck.env</code>. Get the address from the dashboard URL and the credential from
              the dashboard configuration or the operator who runs it. Use <code>https://</code> for a daemon outside
              the local machine; never paste a live credential into this page.
            </p>
          </section>

          <ol class="sd-install-steps">
            <li><a href={@streamdeck_package.url} download><strong>Download the Stream Deck + package.</strong></a></li>
            <li><strong>Create the sidecar directory:</strong> <code>install -dm755 ~/.local/share/aiur/streamdeck</code></li>
            <li><strong>Extract the archive:</strong> <code>tar -xzf /path/to/downloaded-archive.tar.gz -C ~/.local/share/aiur/streamdeck --strip-components=1</code></li>
            <li><strong>Create the pairing directory:</strong> <code>install -dm700 ~/.config/aiur</code></li>
            <li><strong>Create the pairing file:</strong> <code>touch ~/.config/aiur/streamdeck.env</code></li>
            <li><strong>Restrict the pairing file:</strong> <code>chmod 600 ~/.config/aiur/streamdeck.env</code></li>
            <li><strong>Add the daemon values</strong> for <code>AIUR_PHOENIX_URL</code>, <code>AIUR_DASHBOARD_USERNAME</code>, and <code>AIUR_DASHBOARD_PASSWORD</code>.</li>
            <li><strong>Install the udev rule:</strong> <code>sudo install -Dm644 ~/.local/share/aiur/streamdeck/share/udev/70-streamdeck.rules /etc/udev/rules.d/70-streamdeck.rules</code></li>
            <li><strong>Install the user unit:</strong> <code>install -Dm644 ~/.local/share/aiur/streamdeck/share/systemd/aiur-streamdeck.service ~/.config/systemd/user/aiur-streamdeck.service</code></li>
            <li><strong>Reload user systemd:</strong> <code>systemctl --user daemon-reload</code></li>
            <li><strong>Enable the sidecar:</strong> <code>systemctl --user enable --now aiur-streamdeck.service</code></li>
            <li><strong>Plug in the deck.</strong> The sidecar detects it and paints the fleet.</li>
          </ol>

          <section class="sd-install-result" aria-labelledby="streamdeck-success-title">
            <h3 id="streamdeck-success-title">What success looks like</h3>
            <p>The deck shows your Aiur fleet. If it does not, first check <code>systemctl --user status aiur-streamdeck.service</code>.</p>
          </section>

          <p class="modal-meta">
            <a href={@streamdeck_package.url} download>Download package {@streamdeck_package.version}</a>
            <span aria-hidden="true"> · </span>
            Aiur commit <code>{@streamdeck_package.commit}</code>
          </p>
        </section>
      </div>
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

    if connected?(socket) and is_binary(previous_identifier) and
         previous_identifier != socket.assigns.selected_identifier do
      focus_logs(socket, previous_identifier, socket.assigns.selected_identifier)
    else
      socket
    end
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

  defp screen_descriptors(grid, usage, current_page, focus) do
    live = live_count(grid)

    [
      %{kind: :summary, label: "SUMMARY", logo: "/aiur-logo.png", observed?: grid.total > 0, live: live, remaining: max(grid.total - live, 0), meters: []}
      | Enum.map(CodingAgent.provider_descriptors(), &provider_segment(&1, usage))
    ] ++ [pager_segment(grid, current_page, focus)]
  end

  # A focused command takes the pager segment over: the dots give way to the
  # agent being controlled, matching the design's CONTROLLING relabel.
  defp pager_segment(_grid, current_page, focus) when not is_nil(focus) do
    %{
      kind: :pager,
      label: "CONTROLLING",
      observed?: true,
      pages: [],
      current_page: current_page,
      focus_label: "##{focus.identifier}",
      meters: []
    }
  end

  defp pager_segment(grid, current_page, _focus) do
    %{
      kind: :pager,
      label: "MORE AGENTS",
      observed?: grid.windows > 1,
      pages: pager_pages(grid.windows),
      current_page: current_page,
      focus_label: nil,
      meters: []
    }
  end

  defp pager_focus(%{assigns: %{sd_mode: mode, sd_active: active}}), do: mode_pager_focus(mode, active)

  defp mode_pager_focus(mode, active) when mode in [:cmd, :logs] and not is_nil(active), do: active
  defp mode_pager_focus(_mode, _active), do: nil

  defp refresh_pager(socket) do
    focus = pager_focus(socket)

    screen =
      Enum.map(socket.assigns.screen, fn
        %{kind: :pager} = segment -> pager_segment(socket.assigns.grid, segment.current_page, focus)
        segment -> segment
      end)

    assign(socket, :screen, screen)
  end

  defp live_count(grid), do: Enum.count(grid.agents, &(&1.bucket == :running))

  defp provider_segment(descriptor, usage) do
    provider = Atom.to_string(descriptor.provider)
    meter = Map.get(usage, provider)

    %{
      kind: :provider,
      provider: provider,
      label: descriptor.label,
      logo: descriptor.logo,
      observed?: observed_provider?(meter),
      meters: [provider_meter("session", "Session", meter), provider_meter("weekly", "Weekly", meter)]
    }
  end

  defp provider_meter(key, label, meter) do
    window = if observed_provider?(meter), do: meter |> get_value("windows", %{}) |> get_value(key), else: nil
    percent = window_percentage(window)
    freshness = window_freshness(window)

    %{
      key: key,
      label: label,
      percent: percent,
      metadata: meter_metadata(window, freshness),
      observed?: is_integer(percent),
      freshness: freshness,
      stale?: freshness == "stale"
    }
  end

  defp observed_provider?(%{} = meter), do: get_value(meter, "state") in [:observed, "observed"]
  defp observed_provider?(_meter), do: false

  defp window_metadata(window) when is_map(window) do
    case get_value(window, "remaining") do
      remaining when is_binary(remaining) and remaining != "" -> remaining
      _ -> window |> get_value("resets_at") |> reset_label()
    end
  end

  defp window_metadata(_window), do: nil

  defp window_freshness(window) when is_map(window) do
    case get_value(window, "freshness") do
      freshness when freshness in [:fresh, "fresh", :partial, "partial", :stale, "stale"] -> to_string(freshness)
      _ -> "unknown"
    end
  end

  defp window_freshness(_window), do: "unknown"

  defp meter_metadata(window, freshness) do
    [window_metadata(window), if(freshness == "stale", do: "stale"), stale_age_label(window, freshness)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> nil
      metadata -> metadata
    end
  end

  defp stale_age_label(window, "stale") when is_map(window) do
    case get_value(window, "age_seconds") do
      age_seconds when is_integer(age_seconds) and age_seconds >= 0 -> "#{age_label(age_seconds)} ago"
      _ -> nil
    end
  end

  defp stale_age_label(_window, _freshness), do: nil

  defp age_label(age_seconds) when age_seconds < 60, do: "#{age_seconds}s"
  defp age_label(age_seconds) when age_seconds < 3_600, do: "#{div(age_seconds, 60)}m"
  defp age_label(age_seconds) when age_seconds < 86_400, do: "#{div(age_seconds, 3_600)}h"
  defp age_label(age_seconds), do: "#{div(age_seconds, 86_400)}d"

  defp reset_label(%DateTime{} = reset), do: "#{weekday(reset)} #{hour_label(reset)}"

  defp reset_label(reset) when is_binary(reset) do
    case DateTime.from_iso8601(reset) do
      {:ok, datetime, _offset} -> reset_label(datetime)
      _ -> nil
    end
  end

  defp reset_label(_reset), do: nil

  defp weekday(%DateTime{} = datetime), do: Enum.at(~w(Mon Tue Wed Thu Fri Sat Sun), Date.day_of_week(DateTime.to_date(datetime)) - 1)
  defp hour_label(%DateTime{hour: hour}), do: "#{rem(hour + 11, 12) + 1}#{if(hour < 12, do: "AM", else: "PM")}"

  defp meter_aria_label(%{label: label, observed?: true, percent: percent, metadata: metadata}) do
    Enum.reject([label, "#{percent}%", metadata], &is_nil/1) |> Enum.join(" · ")
  end

  defp meter_aria_label(%{label: label}), do: "#{label} unavailable"

  defp bucket_label(:alert), do: "Alert"
  defp bucket_label(:stuck), do: "Stuck"
  defp bucket_label(:running), do: "Running"
  defp bucket_label(:paused), do: "Paused"
  defp bucket_label(:queued), do: "Queued"

  defp control_action(:running), do: "pause"
  defp control_action(:paused), do: "resume"
  defp control_action(_bucket), do: nil

  # Without a focused agent there is no real pause or priority state to render.
  # Blank every slot rather than showing a control whose label would be a guess.
  defp command_keys(nil), do: List.duplicate(empty_command_key(), 8)

  defp command_keys(agent) do
    paused? = Map.get(agent, :bucket) == :paused
    prioritized? = Map.get(agent, :priority, false)

    [
      command_key(
        "pause",
        if(paused?, do: "Play", else: "Pause"),
        if(paused?, do: "RESUME", else: "HOLD"),
        icon: if(paused?, do: "play", else: "pause")
      ),
      command_key(
        "priority",
        if(prioritized?, do: "Deprioritize", else: "Prioritize"),
        if(prioritized?, do: "LOWER", else: "RAISE"),
        icon: if(prioritized?, do: "down", else: "up")
      ),
      command_key("logs", "Logs", "SCROLL", icon: "logs"),
      command_key("mic", "Mic", "HOLD", icon: "mic", mic?: true),
      empty_command_key(),
      empty_command_key(),
      empty_command_key(),
      empty_command_key()
    ]
  end

  defp command_key(command, label, sub, opts) do
    %{
      command: command,
      label: label,
      sub: sub,
      icon: Keyword.fetch!(opts, :icon),
      mic?: Keyword.get(opts, :mic?, false),
      empty?: false
    }
  end

  defp empty_command_key, do: %{empty?: true, mic?: false}

  defp command_label("pause"), do: "Pause"
  defp command_label("priority"), do: "Priority"
  defp command_label("logs"), do: "Logs"

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
    case Enum.find(socket.assigns.grid.agents, &(to_string(&1.identifier) == identifier)) do
      nil ->
        socket

      agent ->
        previous_identifier = socket.assigns.selected_identifier

        socket
        |> assign(:selected_identifier, identifier)
        |> maybe_assign_active(agent)
        |> focus_logs(previous_identifier, identifier)
    end
  end

  defp select_agent_from_params(socket, _params), do: socket

  defp maybe_assign_active(%{assigns: %{sd_mode: :grid}} = socket, _agent), do: socket
  defp maybe_assign_active(socket, agent), do: socket |> assign(:sd_active, agent) |> refresh_pager()

  defp enter_cmd(socket, %{"identifier" => identifier}) when socket.assigns.sd_mode == :grid do
    case Enum.find(socket.assigns.grid.agents, &(to_string(&1.identifier) == identifier)) do
      nil -> socket
      agent -> socket |> assign(:sd_mode, :cmd) |> assign(:sd_active, agent) |> refresh_pager()
    end
  end

  defp enter_cmd(socket, _params), do: socket

  defp enter_logs(%{assigns: %{sd_mode: :cmd, sd_active: active}} = socket) when not is_nil(active),
    do: assign(socket, :sd_mode, :logs)

  defp enter_logs(socket), do: socket

  defp back(%{assigns: %{sd_mode: :logs}} = socket), do: assign(socket, :sd_mode, :cmd)

  defp back(%{assigns: %{sd_mode: :cmd}} = socket) do
    previous_identifier = socket.assigns.selected_identifier

    socket
    |> assign(:sd_mode, :grid)
    |> assign(:sd_active, nil)
    |> assign_grid(socket.assigns.grid, socket.assigns.grid_column_offset, nil, socket.assigns.grid_dial_value)
    |> focus_logs(previous_identifier, socket.assigns.selected_identifier)
  end

  defp back(socket), do: socket

  defp update_logs(socket, axis, delta) do
    logs = socket.assigns.logs
    offset_key = String.to_existing_atom("#{axis}_offset")
    max_key = String.to_existing_atom("#{axis}_max_offset")
    offset = clamp(Map.fetch!(logs, offset_key) + delta, 0, Map.fetch!(logs, max_key))
    assign(socket, :logs, logs |> Map.put(offset_key, offset) |> StreamdeckLogs.visible())
  rescue
    _ -> socket
  end

  defp load_logs(identifier) when is_binary(identifier) do
    entries =
      case endpoint_config(:streamdeck_logs_fun) do
        fun when is_function(fun, 1) -> safe_call(fn -> fun.(identifier) end, [])
        fun when is_function(fun, 0) -> safe_call(fun, [])
        _ -> safe_call(fn -> agent_event_feed(identifier) end, [])
      end

    entries
    |> log_entries()
    |> StreamdeckLogs.project()
  end

  defp load_logs(_identifier), do: StreamdeckLogs.project([])

  defp agent_event_feed(identifier) do
    case AgentEventFeed.list(identifier, %{"limit" => 50}) do
      {:ok, %{events: events}} -> events
      _ -> []
    end
  end

  defp log_entries(%{events: events}) when is_list(events), do: events
  defp log_entries(%{"events" => events}) when is_list(events), do: events
  defp log_entries(entries) when is_list(entries), do: entries
  defp log_entries(_entries), do: []

  defp maybe_subscribe_fixture_fleet do
    if endpoint_config(:streamdeck_fixture_fleet) do
      Phoenix.PubSub.subscribe(Aiur.PubSub, "streamdeck:fixture")
    end

    :ok
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
       when mode in [:cmd, :logs] and not is_nil(active) do
    identifier = to_string(active.identifier)
    refreshed_active = Enum.find(grid.agents, active, &(to_string(&1.identifier) == identifier))
    {identifier, refreshed_active}
  end

  defp mode_focus(socket, grid, visible_agents) do
    {selected_identifier(socket, grid, visible_agents), socket.assigns.sd_active}
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

  defp replace_transcript_relay(socket, previous_identifier, identifier) do
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

  defp focus_logs(socket, previous_identifier, identifier) when previous_identifier != identifier do
    socket
    |> assign(:logs, load_logs(identifier))
    |> replace_transcript_relay(previous_identifier, identifier)
  end

  defp focus_logs(socket, _previous_identifier, _identifier), do: socket

  defp transcript_flush_ms do
    Endpoint.config(:streamdeck_transcript_flush_ms) ||
      Application.get_env(:aiur, Endpoint, []) |> Keyword.get(:streamdeck_transcript_flush_ms) || 250
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
