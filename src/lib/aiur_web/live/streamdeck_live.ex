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
  alias AiurWeb.{Endpoint, StreamDeckGrid, StreamdeckProjection}
  alias AiurWeb.OperatorControlCenter.{DashboardShell, NavState, RouteRegistry}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> NavState.assign_nav()
      |> assign(:current_route, RouteRegistry.current_route(:streamdeck))
      |> assign(:knobs, knob_descriptors())
      |> assign(:control_feedback, nil)
      |> assign(:tracker_kind, kind(&Aiur.Config.tracker_kind/0, "tracker unavailable"))
      |> assign(:agent_kind, kind(&Aiur.Config.agent_kind/0, "agent unavailable"))
      |> refresh_grid()

    if connected?(socket) do
      :ok = AgentPubSub.subscribe_running()
      :ok = AgentPubSub.subscribe_status()
      :ok = ProviderMeterEvents.subscribe_observed()
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle-nav", _params, socket), do: {:noreply, NavState.toggle(socket)}

  def handle_event("restore-nav", %{"collapsed" => collapsed}, socket),
    do: {:noreply, NavState.restore(socket, collapsed)}

  def handle_event("key-press", params, socket) do
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
  def handle_info({:running_changed, _summaries}, socket), do: {:noreply, refresh_grid(socket)}

  def handle_info({:status_changed, %{identifier: _identifier}}, socket),
    do: {:noreply, refresh_grid(socket)}

  def handle_info({:provider_meter_changed, _snapshot}, socket), do: {:noreply, refresh_grid(socket)}

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

          <ul id="sd-keys" class="sd-keys" data-mode-view="grid" aria-label="Agent keys" data-grid-total={@grid.total} data-grid-windows={@grid.windows}>
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
            <div class="sd-log-body">
              <p class="sd-log-line">No recent log output.</p>
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

    socket
    |> assign(:grid, grid)
    |> assign(:keys, key_descriptors(grid))
    |> assign(:screen, screen_descriptors(grid, usage))
  end

  defp key_descriptors(%{agents: agents}) do
    visible_agents = Enum.take(agents, 8)
    empty_slots = if length(visible_agents) < 8, do: Enum.map((length(visible_agents) + 1)..8, &empty_key/1), else: []

    visible_agents
    |> Enum.with_index(1)
    |> Enum.map(fn {agent, slot} -> agent_key(slot, agent) end)
    |> Kernel.++(empty_slots)
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

  defp empty_key(slot), do: %{slot: slot, bucket: "empty", identifier: nil, control_action: nil, empty?: true}

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
    case Map.get(meter, "windows") do
      windows when is_map(windows) -> "#{map_size(windows)} windows"
      _ -> Map.get(meter, "state", "observed") |> to_string()
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
      {:ok, _request_id} -> assign(socket, :control_feedback, "Pause requested for ##{identifier}")
      {:error, reason} -> assign(socket, :control_feedback, "Pause failed: #{inspect(reason)}")
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
        fun when is_function(fun, 0) -> safe_call(fun, %{})
        _ -> safe_call(fn -> Orchestrator.snapshot(orchestrator(), snapshot_timeout_ms()) end, %{})
      end

    case snapshot do
      %{} = snapshot -> StreamDeckGrid.project(snapshot)
      _ -> empty_grid()
    end
  end

  defp empty_grid do
    %{agents: [], total: 0, columns_per_page: 4, rows_per_column: 2, agents_per_page: 8, windows: 0, max_column_offset: 0}
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

  defp knob_descriptors do
    [
      %{label: "Focus", value: "62", angle: 138},
      %{label: "Volume", value: "74", angle: 174},
      %{label: "Speed", value: "48", angle: 78},
      %{label: "Page", value: "01", angle: 36}
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
