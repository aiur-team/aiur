defmodule AiurWeb.StreamdeckLive do
  @moduledoc """
  Browser emulator for the Stream Deck control surface.

  The view renders the same orchestrator snapshot projection used by the
  Stream Deck API and subscribes to the fleet topics so browser state follows
  the dashboard. Key presses use the existing AgentChat control facade; the
  orchestrator remains the authority for the resulting pause/resume state.

  Logs mode subscribes the focused agent through `StreamdeckTranscriptRelay`
  and projects the durable classified feed (`AgentEventFeed`) through
  `StreamdeckLogs`. That projection is one newest-first document read at two
  granularities: the eight keys are the event index (LIVE first, then a
  scrolling window of event rows) and the touch strip is the transcript text at
  the selected event's offset. Selecting a key positions the strip; scrolling
  the strip reselects the event under the cursor. The production path reads the
  real feed; `streamdeck_logs_fun` exists only as a test seam.
  """

  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias Aiur.{AgentChat, AgentEventFeed, AgentPubSub, CodingAgent, Orchestrator}
  alias Aiur.ProviderMeters.Events, as: ProviderMeterEvents

  alias AiurWeb.{
    Endpoint,
    StreamDeckGrid,
    StreamdeckKeyFaceContract,
    StreamdeckLogs,
    StreamdeckProjection,
    StreamdeckStrip,
    StreamdeckTranscriptRelay
  }

  alias AiurWeb.OperatorControlCenter.{
    AwaitingCommands,
    BuildOrderEpicIcon,
    DashboardShell,
    NavState,
    Overview,
    RouteRegistry
  }

  @relative_time_refresh_ms 1_000
  @durable_feed_retry_attempts 2
  @durable_feed_retry_ms 50

  # The two fleet-control commands. Each is a single key whose direction the
  # server resolves from orchestrator state, so the client never names the
  # action — it only names the key it pressed.
  @control_commands ~w(pause priority)

  @streamdeck_package %{
    version: "0.0.0-dev.0098e3ac86a2",
    commit: "0098e3ac86a2e49e685e8e6ff67248373de43f1d",
    url:
      "https://github.com/aiur-team/aiur/releases/download/streamdeck-0098e3ac86a2e49e685e8e6ff67248373de43f1d/" <>
        "aiur-streamdeck-0.0.0-dev.0098e3ac86a2-linux-x64-c6d1f373b30d8f038538becd746acb43ea2d4364501dc7ced4e65819e9bc76c3.tar.gz"
  }

  # The web emulator's own drawing routine, fed entirely by the shared key-face
  # contract: a state's colours are stated once, in the contract, and reach the
  # page as CSS custom properties keyed by the same `st-<bucket>` class the
  # packaged deck keys its bitmaps by.
  @key_face_css StreamdeckKeyFaceContract.states()
                |> Enum.sort_by(fn {_bucket, state} -> state["rank"] end)
                |> Enum.map_join("", fn {bucket, state} ->
                  pulse =
                    case state["pulse_seconds"] do
                      seconds when is_number(seconds) ->
                        ".sd-agent-key.st-#{bucket} .sd-ag-dot,.sd-agent-key.st-#{bucket} .sd-ag-stat::before{animation:sd-pulse #{seconds}s ease-in-out infinite;}"

                      _absent ->
                        ""
                    end

                  ".sd-key.st-#{bucket}{--sd-accent:#{state["accent"]};--sd-glow:#{state["glow"]};--sd-face:#{state["face"]};}" <>
                    ".sd-key.st-#{bucket} .sd-key-face{background:var(--sd-face);}" <> pulse
                end)
                |> then(&Phoenix.HTML.raw("<style>" <> &1 <> "</style>"))

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> NavState.assign_nav()
      |> AwaitingCommands.mount(connected?(socket))
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

        socket
        |> replace_transcript_relay(nil, socket.assigns.selected_identifier)
        |> schedule_relative_time_refresh()
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

  def handle_event("log-key-select", %{"index" => index}, socket) do
    {:noreply, socket |> assign(:logs, StreamdeckLogs.select_event(socket.assigns.logs, parse_integer(index, 0))) |> refresh_knobs()}
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

  def handle_event("command-press", %{"command" => command}, socket) when command in @control_commands do
    if dashboard_writable?() do
      {:noreply, invoke_command(socket, command)}
    else
      {:noreply, assign(socket, :control_feedback, "Read-only dashboard: controls are disabled")}
    end
  end

  def handle_event("command-press", _params, socket), do: {:noreply, socket}

  def handle_event("dial-press", %{"action" => "back"}, socket), do: {:noreply, back(socket)}

  def handle_event("dial-press", %{"action" => "cycle-window"}, socket),
    do: {:noreply, enter_logs(socket)}

  def handle_event("dial-press", %{"index" => _index, "action" => _action}, socket), do: {:noreply, socket}

  # Mic is press-and-hold, so the server tracks the held state rather than
  # toggling it: a `pointerup`/`pointerleave`/`pointercancel` that never arrives
  # must not leave the key latched live. Read-only refuses the hold outright,
  # matching the server-side gate on the click-driven control commands.
  def handle_event("mic-hold", %{"active" => active}, socket) do
    cond do
      not dashboard_writable?() ->
        {:noreply,
         socket
         |> assign(:mic_held?, false)
         |> assign(:control_feedback, "Read-only dashboard: controls are disabled")}

      truthy?(active) ->
        {:noreply, assign(socket, :mic_held?, true)}

      true ->
        {:noreply, assign(socket, :mic_held?, false)}
    end
  end

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
      {:noreply, socket |> reload_logs(identifier) |> schedule_durable_feed_refresh(identifier)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:streamdeck_alert, identifier, _event}, socket) when is_binary(identifier) do
    if socket.assigns.selected_identifier == identifier do
      {:noreply, socket |> reload_logs(identifier) |> schedule_durable_feed_refresh(identifier)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:streamdeck_control, identifier, _payload}, socket) when is_binary(identifier) do
    if socket.assigns.selected_identifier == identifier do
      {:noreply, socket |> reload_logs(identifier) |> schedule_durable_feed_refresh(identifier)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:refresh_streamdeck_durable_feed, identifier, attempts}, socket)
      when is_binary(identifier) and is_integer(attempts) do
    if socket.assigns.selected_identifier == identifier do
      {:noreply, socket |> reload_logs(identifier) |> schedule_durable_feed_refresh(identifier, attempts)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:decision_changed, _decision_id, _version}, socket),
    do: {:noreply, AwaitingCommands.refresh(socket)}

  def handle_info(:awaiting_commands_tick, socket), do: {:noreply, AwaitingCommands.tick(socket)}

  def handle_info(:refresh_streamdeck_relative_times, socket) do
    socket =
      if socket.assigns.sd_mode == :logs do
        assign(socket, :logs, StreamdeckLogs.refresh_relative_times(socket.assigns.logs))
      else
        socket
      end

    {:noreply, schedule_relative_time_refresh(socket)}
  end

  # The awaiting-Commands banner subscribes this view to the Command topic, and
  # that topic carries more than the one message the banner reads —
  # `:decision_metrics_changed` rides the same channel. Without this clause an
  # unrelated Command action anywhere in the fleet takes down the Stream Deck,
  # which is a control surface the operator runs the fleet from.
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <DashboardShell.dashboard_shell
      route={@current_route}
      routes={RouteRegistry.routes(%{})}
      tracker_kind={@tracker_kind}
      agent_kind={@agent_kind}
      nav_collapsed={@nav_collapsed}
      nav_counts={@nav_counts}
    >
      <:banner>
        <Overview.decisions_banner retained_counts={@retained_counts} navigate />
      </:banner>

      {key_face_css()}

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
          <div id="sd-keys" class="sd-keys" role="group" data-mode-view="grid" aria-label="Agent keys" data-grid-total={@grid.total} data-grid-windows={@grid.windows} data-grid-page={@grid_page} data-grid-page-count={@grid.windows} data-grid-column-offset={@grid_column_offset} data-grid-dial-value={@grid_dial_value} data-grid-selected-identifier={@selected_identifier}>
            <button
              :for={key <- @keys}
              type="button"
              class={["sd-key", "sd-agent-key", key.empty? && "is-empty", "st-#{key.bucket}"]}
              disabled={key.empty?}
              style={key.style}
              aria-hidden={to_string(key.empty?)}
              data-streamdeck-key={key.slot}
              data-streamdeck-identifier={key.identifier}
              data-control-action={key.control_action}
            >
              <div class={["sd-key-face", !key.empty? && "sd-agent"]}>
                <div :if={!key.empty?} class="sd-agent-top">
                  <BuildOrderEpicIcon.build_order_epic_icon lane={key.icon} class="sd-ag-ic" />
                  <img :if={key.vendor_logo} class="sd-ag-vendor" src={key.vendor_logo} alt="" />
                  <span :if={!key.vendor_logo} class="sd-ag-vendor-fallback" role="img" aria-label="Unknown provider">◌</span>
                  <span class="sd-ag-idwrap">
                    <span :if={key.priority?} class="sd-ag-prio" aria-label="Prioritized">
                      <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 3l2.6 5.7 6.2.6-4.7 4.2 1.4 6.1L12 17l-5.5 2.6 1.4-6.1L3.2 9.3l6.2-.6z" /></svg>
                    </span>
                    <span class="sd-ag-id">{key.ticket}</span>
                  </span>
                </div>
                <span :if={!key.empty?} class="sd-ag-title">{key.title}</span>
                <div :if={!key.empty? and key.bucket == "queued"} class="sd-ag-foot col">
                  <span class="sd-ag-stat">{key.label}</span>
                  <span class={["sd-ag-tag", key.dependency_ready? && "ready", !key.dependency_ready? && "blocked"]}>{key.dependency}</span>
                </div>
                <div :if={!key.empty? and key.bucket != "queued"} class="sd-ag-foot">
                  <span class="sd-ag-dot" aria-hidden="true"></span>
                  <span class="sr-only">{key.label}</span>
                  <span class="sd-ag-bar" role="progressbar" aria-valuenow={key.progress} aria-valuemin="0" aria-valuemax="100" aria-label={"#{key.progress}% complete"}><i style={"width: #{key.progress}%"}></i></span>
                </div>
              </div>
            </button>
          </div>

          <% end %>

          <%= if @sd_mode == :cmd do %>
          <%!-- The live region stays screen-reader-only until there is something to
               say, so a control failure becomes visible on the deck face rather than
               being announced only to assistive tech. --%>
          <p id="sd-control-status" class={[!@control_feedback && "sr-only", @control_feedback && "sd-control-status"]} role="status" aria-live="polite">{control_feedback(@control_feedback)}</p>
          <ul id="sd-keys" class="sd-keys sd-cmd-keys" data-mode-view="cmd" aria-label="Available commands">
            <li :for={key <- command_keys(@sd_active, @mic_held?)} class={["sd-key", "sd-cmd-key", key.mic? && "sd-mic-key", key.mic? && @mic_held? && "mic-live", key.empty? && "is-empty", !key.empty? && key.disabled? && "is-disabled"]} aria-hidden={to_string(key.empty?)}>
              <button :if={!key.empty?} type="button" class="sd-key-face" data-streamdeck-command={key.command} data-command-state={key.state} data-command-hold={key.mic? && "true"} data-streamdeck-identifier={@selected_identifier} disabled={key.disabled?} aria-disabled={to_string(key.disabled?)} aria-label={key.label}>
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
            <ul id="sd-log-keys" class="sd-keys sd-log-keys" aria-label="Log event keys" data-offset={@logs.events_offset} data-max-offset={@logs.events_max_offset}>
              <li
                :for={key <- @logs.event_keys_visible}
                class={["sd-key", "sd-log-key", key.kind == :empty && "is-empty", key.kind == :live && "sd-live-key is-live", key.index == @logs.selected_event_index && "is-selected"]}
                data-log-event-index={key.index}
                aria-hidden={to_string(key.kind == :empty)}
                aria-current={if key.index == @logs.selected_event_index, do: "true", else: "false"}
                aria-label={log_key_label(key)}
                role={if key.kind == :empty, do: nil, else: "button"}
                tabindex={if key.kind == :empty, do: nil, else: "0"}
              >
                <div :if={key.kind == :empty} class="sd-key-face"></div>
                <div :if={key.kind == :live} class="sd-key-face sd-live-key-face">
                  <span class="sd-live-dot" aria-hidden="true"></span>
                  <span class="sd-live-label">{key.label}</span>
                </div>
                <div :if={key.kind == :event} class="sd-key-face sd-log-key-face">
                  <span class="sd-log-dir sd-log-badge" data-dir={key.badge} style={log_badge_style(key.badge)}>{key.badge}</span>
                  <span class="sd-log-text">{key.text}</span>
                  <span class="sd-log-time">{key.time}</span>
                </div>
              </li>
            </ul>
            <%!-- SP-203 turned the event window into the key faces above, so this
                  pane no longer paints event lines. It stays as the event
                  window's state mirror — the same role #sd-log-transcript plays
                  below, both hidden by .sd-log-body — so the offset bounds that
                  drive the dial-D EVENTS hint remain observable. --%>
            <div id="sd-log-events" class="sd-log-body" data-offset={@logs.events_offset} data-max-offset={@logs.events_max_offset}>
              <span id="sd-events-hint-up" class="sd-log-hint" aria-hidden={to_string(@logs.events_offset == 0)}>↑</span>
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

          <div
            id="sd-screen"
            class={["sd-screen", "sd-screen-#{@sd_mode}"]}
            style={"--sd-screen-segments: #{length(@screen)}"}
            data-transcript-offset={@logs.transcript_offset}
            data-transcript-max-offset={@logs.transcript_max_offset}
            role="group"
            aria-label="Touch strip"
          >
            <%= if @sd_mode == :cmd do %>
            <% command = StreamdeckStrip.command(@sd_active) %>
            <div class={["sd-strip-cmd", "st-#{@sd_active.bucket}"]} style={"--sd-accent: #{command.accent}"} data-mode-view="cmd-strip">
              <div class="sd-strip-cmd-heading">
                <span class="sd-strip-cmd-agent-icon" aria-hidden="true">{command.icon}</span>
                <img :if={command.provider_logo} class="sd-cmd-provider-logo" src={command.provider_logo} alt={command.provider} />
                <span class="sd-strip-cmd-provider">{String.upcase(command.provider)}</span>
                <span class="sd-strip-cmd-pager">CONTROLLING #{command.number}</span>
              </div>
              <div class="sd-strip-cmd-body">
                <span class="sd-strip-cmd-ticket">#{command.number}</span>
                <span class="sd-strip-cmd-title">{command.title}</span>
                <span class="sd-strip-cmd-status">{command.status}</span>
                <span class="sd-strip-cmd-percent">{command.percent}%</span>
              </div>
              <span class="sd-strip-cmd-progress" role="progressbar" aria-valuenow={command.percent} aria-valuemin="0" aria-valuemax="100">
                <i style={"width: #{command.percent}%; background: #{command.progress_colour}"}></i>
              </span>
            </div>
            <% end %>
            <div :if={@sd_mode == :logs} class="sd-strip-logs" data-mode-view="logs-strip">
              <div :for={entry <- StreamdeckStrip.entries(@logs.transcript_visible)} class={["sd-log-strip-entry", "sd-log-entry-#{entry.shape}"]} data-log-kind={entry.shape}>
                <div :if={entry.shape == :evhdr} class="sd-log-evhdr">
                  <span class="sd-log-evhdr-direction" style={"color: #{entry.colour}"}>{entry.direction}</span>
                  <span class="sd-log-evhdr-text">{entry.text}</span>
                  <span class="sd-log-evhdr-time">{entry.time}</span>
                </div>
                <div :if={entry.shape == :diff} class="sd-log-diff">
                  <span class="sd-log-diff-file">{entry.file}</span>
                  <span class="sd-log-diff-counts"><b>+{entry.additions}</b> <b>-{entry.deletions}</b></span>
                  <code class={["sd-log-diff-line", "is-#{entry.line_kind}"]}>{entry.line}</code>
                </div>
                <div :if={entry.shape == :message} class="sd-log-message">
                  <span class={["sd-log-speaker", "is-#{entry.speaker}"]}>{entry.speaker}</span>
                  <span class="sd-log-message-text">{entry.text}</span>
                </div>
              </div>
              <p :if={@logs.transcript_visible == []} class="sd-log-strip-empty">No recent transcript.</p>
            </div>
            <div
              :for={segment <- @screen}
              :if={@sd_mode == :grid or segment.kind == :pager}
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
                <span :if={is_nil(knob.hint)} aria-hidden="true">{knob.label}</span>
                <span :if={knob.hint} class="sd-dial-hint">
                  <span style={"visibility: " <> if(knob.hint.older?, do: "visible", else: "hidden")}>‹</span>{knob.hint.label}<span style={"visibility: " <> if(knob.hint.newer?, do: "visible", else: "hidden")}>›</span>
                </span>
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
    |> refresh_knobs()
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
    footer = StreamdeckKeyFaceContract.footer_for_agent(bucket, agent)

    key(
      slot,
      Atom.to_string(bucket),
      Map.get(agent, :identifier),
      Map.get(agent, :title, "Untitled"),
      footer.label,
      Map.get(agent, :progress_percent, 0),
      identifier: Map.get(agent, :identifier),
      control_action: control_action(bucket),
      priority?: Map.get(agent, :priority, false),
      icon: Map.get(agent, :icon),
      vendor_logo: Map.get(agent, :vendor_logo),
      dependency_ready?: footer.ready?,
      dependency: footer.dependency,
      style: key_style(Map.get(agent, :progress_percent, 0))
    )
  end

  defp key(slot, bucket, ticket, title, label, progress, opts) do
    %{
      slot: slot,
      bucket: bucket,
      ticket: ticket,
      title: title,
      label: label,
      progress: progress,
      priority?: Keyword.get(opts, :priority?, false),
      dependency_ready?: Keyword.get(opts, :dependency_ready?, false),
      icon: Keyword.get(opts, :icon),
      vendor_logo: Keyword.get(opts, :vendor_logo),
      dependency: Keyword.get(opts, :dependency),
      identifier: Keyword.get(opts, :identifier, ticket),
      control_action: Keyword.get(opts, :control_action),
      style: Keyword.fetch!(opts, :style),
      empty?: false
    }
  end

  defp empty_key(slot),
    do: %{slot: slot, bucket: "empty", identifier: nil, control_action: nil, style: nil, empty?: true}

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

  defp key_face_css, do: @key_face_css

  defp key_style(progress), do: "--sd-progress-fill: #{StreamdeckKeyFaceContract.progress_color(progress)}"

  defp log_badge_style(badge), do: "--sd-log-badge: #{StreamdeckKeyFaceContract.direction_badge!(badge)["color"]}"

  defp control_action(:running), do: "pause"
  defp control_action(:paused), do: "resume"
  defp control_action(_bucket), do: nil

  # Without a focused agent there is no real pause or priority state to render.
  # Blank every slot rather than showing a control whose label would be a guess.
  defp command_keys(nil, _mic_held?), do: List.duplicate(empty_command_key(), 8)

  # The command keys are derived from the agent the orchestrator currently
  # reports, never from an optimistic local toggle, so a control call that the
  # orchestrator rejects leaves the key showing the state that actually holds.
  defp command_keys(agent, mic_held?) do
    writable? = dashboard_writable?()

    [
      pause_command_key(Map.get(agent, :bucket) == :paused, writable?),
      priority_command_key(Map.get(agent, :priority) == true, writable?),
      # Logs is navigation rather than fleet control, so read-only leaves it
      # enabled: it changes what the operator sees, never what the fleet does.
      command_key("logs", "Logs", "SCROLL", icon: "logs", state: "ready"),
      # Mic is the design's fourth command and the only press-and-hold one: it
      # carries no click handler, so the hook drives it from pointer events.
      mic_command_key(mic_held?, writable?),
      empty_command_key(),
      empty_command_key(),
      empty_command_key(),
      empty_command_key()
    ]
  end

  defp pause_command_key(true, writable?),
    do: command_key("pause", "Play", "RESUME", icon: "play", state: "paused", disabled?: not writable?)

  defp pause_command_key(false, writable?),
    do: command_key("pause", "Pause", "HOLD", icon: "pause", state: "running", disabled?: not writable?)

  defp priority_command_key(true, writable?),
    do: command_key("priority", "Deprioritize", "LOWER", icon: "down", state: "prioritized", disabled?: not writable?)

  defp priority_command_key(false, writable?),
    do: command_key("priority", "Prioritize", "RAISE", icon: "up", state: "standard", disabled?: not writable?)

  defp mic_command_key(true, writable?),
    do: command_key("mic", "Mic", "HOLD", icon: "mic", mic?: true, state: "live", disabled?: not writable?)

  defp mic_command_key(false, writable?),
    do: command_key("mic", "Mic", "HOLD", icon: "mic", mic?: true, state: "idle", disabled?: not writable?)

  defp command_key(command, label, sub, opts) do
    %{
      command: command,
      label: label,
      sub: sub,
      icon: Keyword.fetch!(opts, :icon),
      mic?: Keyword.get(opts, :mic?, false),
      state: Keyword.get(opts, :state, "ready"),
      disabled?: Keyword.get(opts, :disabled?, false),
      empty?: false
    }
  end

  defp empty_command_key, do: %{empty?: true, mic?: false}

  defp invoke_command(socket, command) do
    case socket.assigns.sd_active do
      %{identifier: identifier} = agent when not is_nil(identifier) ->
        socket
        |> invoke_agent_control(to_string(identifier), control_action_for(command, agent))
        |> refresh_grid()

      _agent ->
        assign(socket, :control_feedback, "No agent selected")
    end
  end

  # Each control key is a single toggle, and the direction is resolved from the
  # state the orchestrator reports rather than from the label the client
  # happened to be rendering. A stale key still reading "Pause" therefore cannot
  # re-pause an agent the orchestrator has already paused.
  defp control_action_for("pause", %{bucket: :paused}), do: :resume
  defp control_action_for("pause", _agent), do: :pause
  defp control_action_for("priority", %{priority: true}), do: :deprioritize
  defp control_action_for("priority", _agent), do: :prioritize

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

  defp invoke_agent_control(socket, identifier, :prioritize) do
    case safe_control_call(fn -> prioritize_agent(identifier) end) do
      {:ok, _result} -> assign(socket, :control_feedback, "Prioritize requested for ##{identifier}")
      {:error, reason} -> assign(socket, :control_feedback, "Prioritize failed: #{inspect(reason)}")
    end
  end

  defp invoke_agent_control(socket, identifier, :deprioritize) do
    case safe_control_call(fn -> deprioritize_agent(identifier) end) do
      {:ok, _result} -> assign(socket, :control_feedback, "Deprioritize requested for ##{identifier}")
      {:error, reason} -> assign(socket, :control_feedback, "Deprioritize failed: #{inspect(reason)}")
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
      agent -> socket |> assign(:sd_mode, :cmd) |> assign(:sd_active, agent) |> refresh_pager() |> refresh_knobs()
    end
  end

  defp enter_cmd(socket, _params), do: socket

  defp enter_logs(%{assigns: %{sd_mode: :cmd, sd_active: active}} = socket) when not is_nil(active),
    do: socket |> assign(:sd_mode, :logs) |> refresh_knobs()

  defp enter_logs(socket), do: socket

  defp back(%{assigns: %{sd_mode: :logs}} = socket), do: socket |> assign(:sd_mode, :cmd) |> refresh_knobs()

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
    axis = String.to_existing_atom(axis)
    socket |> assign(:logs, StreamdeckLogs.scroll(socket.assigns.logs, axis, delta)) |> refresh_knobs()
  rescue
    _ -> socket
  end

  defp load_logs(identifier) when is_binary(identifier) do
    identifier |> load_log_entries() |> StreamdeckLogs.project()
  end

  defp load_logs(_identifier), do: StreamdeckLogs.project([])

  defp reload_logs(socket, identifier) do
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
    case AgentEventFeed.list(identifier, %{"limit" => 50}) do
      {:ok, %{events: events}} -> events
      _ -> []
    end
  end

  defp log_entries(%{events: events}) when is_list(events), do: events
  defp log_entries(%{"events" => events}) when is_list(events), do: events
  defp log_entries(entries) when is_list(entries), do: entries
  defp log_entries(_entries), do: []

  defp log_key_label(%{kind: :live}), do: "LIVE"
  defp log_key_label(%{kind: :event, badge: badge, text: text, time: time}), do: "#{badge}: #{text}, #{time}"
  defp log_key_label(_key), do: nil

  defp schedule_relative_time_refresh(socket) do
    Process.send_after(self(), :refresh_streamdeck_relative_times, @relative_time_refresh_ms)
    socket
  end

  defp schedule_durable_feed_refresh(socket, identifier, attempts \\ @durable_feed_retry_attempts)

  defp schedule_durable_feed_refresh(socket, identifier, attempts)
       when is_binary(identifier) and is_integer(attempts) and attempts > 0 do
    Process.send_after(self(), {:refresh_streamdeck_durable_feed, identifier, attempts - 1}, @durable_feed_retry_ms)
    socket
  end

  defp schedule_durable_feed_refresh(socket, _identifier, _attempts), do: socket

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

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

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

  defp prioritize_agent(identifier) do
    case endpoint_config(:agent_chat_prioritize_fun) do
      fun when is_function(fun, 1) -> fun.(identifier)
      _fun -> AgentChat.prioritize(identifier)
    end
  end

  defp deprioritize_agent(identifier) do
    case endpoint_config(:agent_chat_deprioritize_fun) do
      fun when is_function(fun, 1) -> fun.(identifier)
      _fun -> AgentChat.deprioritize(identifier)
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

  defp refresh_knobs(socket) do
    assign(socket, :knobs, knob_descriptors(socket.assigns.grid_dial_value, socket.assigns.grid.windows, socket.assigns.sd_mode, socket.assigns.logs))
  end

  defp knob_descriptors(dial_value \\ 0, windows \\ 0, mode \\ :grid, logs \\ %{}) do
    back_hint =
      case mode do
        :cmd -> StreamdeckStrip.hint(0, 0, "BACK")
        :logs -> StreamdeckStrip.hint(Map.get(logs, :transcript_offset, 0), Map.get(logs, :transcript_max_offset, 0), "BACK")
        _ -> nil
      end

    events_hint =
      if mode == :logs,
        do: StreamdeckStrip.hint(Map.get(logs, :events_offset, 0), Map.get(logs, :events_max_offset, 0), "EVENTS"),
        else: nil

    [
      %{label: "Focus", value: "62", angle: 138, hint: back_hint},
      %{label: "Volume", value: "74", angle: 174, hint: nil},
      %{label: "Speed", value: "48", angle: 78, hint: nil},
      %{
        label: "Page",
        value: String.pad_leading(to_string(dial_value), 2, "0"),
        angle: if(windows > 0, do: dial_value / 100 * 270 - 135, else: -135),
        hint: events_hint
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
    |> refresh_knobs()
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
