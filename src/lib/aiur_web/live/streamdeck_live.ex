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

  import AiurWeb.StreamdeckLive.Env, only: [dashboard_writable?: 0, endpoint_config: 1]
  import AiurWeb.StreamdeckLive.Grid
  import AiurWeb.StreamdeckLive.Modes

  alias AiurWeb.StreamdeckLive.{Components, ScreenComponents, Surface}
  alias AiurWeb.StreamdeckLogs

  alias AiurWeb.OperatorControlCenter.{
    AwaitingCommands,
    DashboardShell,
    NavState,
    Overview,
    RouteRegistry
  }

  @relative_time_refresh_ms 1_000
  @durable_feed_retry_attempts 2
  @durable_feed_retry_ms 50

  # The fleet-control commands. Pause is a single key whose direction the server
  # resolves from orchestrator state, so the client never names the action — it
  # only names the key it pressed.
  #
  # Prioritize was the second one and is gone: the agent view's four slots are
  # pause, logs, mic and settings. Orchestrator priority is untouched and stays
  # reachable from the dashboard's own controls.
  @control_commands ~w(pause)

  # The rolling `streamdeck-nightly` pre-release replaces this fixed-name asset
  # in place whenever `packages/streamdeck` changes, so the link never goes
  # stale and never needs a per-commit release to exist. The manifest beside it
  # (`aiur-streamdeck-nightly-linux-x64.json`) records the commit and SHA-256.
  @streamdeck_package %{
    channel: "nightly",
    url:
      "https://github.com/aiur-team/aiur/releases/download/streamdeck-nightly/" <>
        "aiur-streamdeck-nightly-linux-x64.tar.gz"
  }

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> NavState.assign_nav()
      |> AwaitingCommands.mount(connected?(socket))
      |> assign(:current_route, RouteRegistry.current_route(:streamdeck))
      |> assign(:knobs, Surface.knob_descriptors())
      |> assign(:grid_page, 0)
      |> assign(:grid_column_offset, 0)
      |> assign(:grid_dial_value, 0)
      |> assign(:sd_mode, :grid)
      |> assign(:sd_active, nil)
      |> assign(:transcript_relay, nil)
      |> assign(:commands, %{"items" => [], "unavailable" => false})
      |> assign(:commands_view, :history)
      |> assign(:commands_selection, nil)
      |> assign(:commands_option, nil)
      |> assign(:commands_offset, 0)
      |> assign(:commands_cursor, nil)
      |> assign(:commands_page_index, 0)
      |> assign(:commands_error, nil)
      |> assign(:logs, StreamdeckLogs.project([]))
      |> assign(:control_feedback, nil)
      |> assign(:install_modal?, false)
      |> assign(:streamdeck_package, streamdeck_package())
      |> assign(:mic_held?, false)
      |> assign(:tracker_kind, kind(&Aiur.Config.tracker_kind/0, "tracker unavailable"))
      |> assign(:agent_kind, kind(&Aiur.Config.agent_kind/0, "agent unavailable"))
      |> assign(:os, detect_os(user_agent(socket)))
      |> refresh_grid()

    socket = assign(socket, :logs, load_logs(socket.assigns.selected_identifier))

    socket =
      if connected?(socket) do
        socket = AiurWeb.RefreshSubscriptions.fleet(socket, &maybe_subscribe_fixture_fleet/0)

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

  def handle_event("command-press", %{"command" => "settings"}, socket), do: {:noreply, enter_settings(socket)}

  def handle_event("command-press", %{"command" => "commands"}, socket), do: {:noreply, enter_commands(socket)}

  def handle_event("command-press", %{"command" => command}, socket) when command in @control_commands do
    if dashboard_writable?() do
      {:noreply, invoke_command(socket, command)}
    else
      {:noreply, assign(socket, :control_feedback, "Read-only dashboard: controls are disabled")}
    end
  end

  def handle_event("command-press", _params, socket), do: {:noreply, socket}

  def handle_event("dial-press", %{"action" => "back"}, socket), do: {:noreply, back(socket)}

  # Dial D (cycle-window) is the focused window's paging knob: in logs it opens
  # the log surface, and on the Commands page it pages the history window
  # forward (or, on the detail view, cycles the option window) — the same
  # deliberate-reading direction as the physical deck.
  def handle_event("dial-press", %{"action" => "cycle-window"}, socket) do
    case socket.assigns.sd_mode do
      :commands -> {:noreply, page_commands(socket)}
      _ -> {:noreply, enter_logs(socket)}
    end
  end

  def handle_event("dial-press", %{"index" => _index, "action" => _action}, socket), do: {:noreply, socket}

  # Selecting a Commands key reads: on the history view it opens one Command's
  # detail, and on the detail view it selects an option for reading. Selecting
  # never commits — the same reading-not-committing rule as the physical deck.
  def handle_event("command-select", %{"index" => index}, socket),
    do: {:noreply, select_command(socket, parse_integer(index, 0))}

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
    {:noreply, refresh_meters(socket)}
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
  def terminate(_reason, socket) do
    # The transcript relay is `start_link`ed to this LiveView, so a normal exit
    # does not kill it through the link alone. Stop it explicitly so focus
    # changes across repeated visits do not leak one subscribed relay per visit.
    if is_pid(socket.assigns[:transcript_relay]) do
      _ = GenServer.stop(socket.assigns.transcript_relay, :normal)
    end

    :ok
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
      nav_counts={@nav_counts}
    >
      <:banner>
        <Overview.decisions_banner retained_counts={@retained_counts} navigate />
      </:banner>

      {Components.key_face_css()}

      <section id="streamdeck-page" class="sd-stage" aria-label="Stream Deck emulator" phx-hook="StreamdeckEmulator">
        <div :if={@control_feedback} id="sd-control-status" class="streamdeck-status" role="status" aria-live="polite">{control_feedback(@control_feedback)}</div>
        <div class="sd-device" data-mode={@sd_mode}>
          <Components.brand />

          <%= if @sd_mode == :grid do %>
          <Components.grid_keys grid={@grid} grid_page={@grid_page} grid_column_offset={@grid_column_offset} grid_dial_value={@grid_dial_value} selected_identifier={@selected_identifier} keys={@keys} />

          <% end %>

          <%= if @sd_mode == :cmd do %>
          <Components.cmd_keys sd_active={@sd_active} mic_held?={@mic_held?} selected_identifier={@selected_identifier} />
          <% end %>

          <%!-- The settings pane is deliberately empty of choices. Microphone
                enumeration happens on the machine running the sidecar, through
                PipeWire or PulseAudio, and the browser has no view of that
                machine's devices. Inventing a picker here would render a list
                that could not be true. --%>
          <%= if @sd_mode == :settings do %>
          <Components.settings_view />
          <% end %>

          <%= if @sd_mode == :logs do %>
          <Components.logs_view sd_active={@sd_active} logs={@logs} />
          <% end %>

          <%!-- The Commands page mirrors the physical deck's history-first
                surface. The browser emulator can read history and options but
                cannot hold a microphone or approve from the browser: like
                Settings, the physical-only parts are stated rather than faked. --%>
          <%= if @sd_mode == :commands do %>
          <Components.commands_view sd_active={@sd_active} commands={@commands} commands_view={@commands_view} commands_selection={@commands_selection} commands_option={@commands_option} commands_offset={@commands_offset} />
          <% end %>

          <ScreenComponents.screen
            sd_mode={@sd_mode}
            screen={@screen}
            logs={@logs}
            sd_active={@sd_active}
            commands={@commands}
            commands_view={@commands_view}
            commands_selection={@commands_selection}
            commands_option={@commands_option}
            commands_offset={@commands_offset}
            commands_page_index={@commands_page_index}
          />

          <Components.knobs knobs={@knobs} />
        </div>
      </section>

      <Components.install_modal install_modal?={@install_modal?} streamdeck_package={@streamdeck_package} os={@os} />
    </DashboardShell.dashboard_shell>
    """
  end

  defp control_feedback(nil), do: ""
  defp control_feedback(feedback), do: feedback

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

  # The install modal tailors its steps to the operator's OS. The User-Agent is
  # read from connect info on mount (never during a dead render, where it can be
  # absent); anything we cannot parse falls back to Linux, the supported target.
  defp user_agent(socket) do
    get_connect_info(socket, :user_agent)
  rescue
    _ -> nil
  end

  defp detect_os(user_agent) when is_binary(user_agent) do
    cond do
      String.contains?(user_agent, "Windows") -> :windows
      String.contains?(user_agent, "Macintosh") or String.contains?(user_agent, "Mac OS") or String.contains?(user_agent, "Darwin") -> :mac
      true -> :linux
    end
  end

  defp detect_os(_user_agent), do: :linux

  # The published package is resolved at runtime so a daemon without a release
  # artifact (the normal state for an unreleased build) can still open the
  # install modal and show the setup steps; only the download link is dropped.
  defp streamdeck_package do
    case endpoint_config(:streamdeck_package) do
      package when is_map(package) -> package
      _unpublished -> @streamdeck_package
    end
  end

  defp kind(provider, fallback) do
    case provider.() do
      value when is_atom(value) or is_binary(value) -> to_string(value)
      _ -> fallback
    end
  rescue
    _ -> fallback
  end
end
