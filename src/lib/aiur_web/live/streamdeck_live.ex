defmodule AiurWeb.StreamdeckLive do
  @moduledoc """
  Read-only browser emulator for the Stream Deck control surface.

  The view deliberately renders descriptor-shaped maps consumed by the physical
  renderer. Until the grid projection and shared key model land, the maps below
  are a complete visual fixture: they keep the emulator useful as a permanent
  chassis and CSS harness without inventing runtime state.
  """

  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias AiurWeb.OperatorControlCenter.{DashboardShell, NavState, RouteRegistry}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> NavState.assign_nav()
     |> assign(:current_route, RouteRegistry.current_route(:streamdeck))
     |> assign(:keys, preview_key_descriptors())
     |> assign(:screen, screen_descriptors())
     |> assign(:knobs, knob_descriptors())
     |> assign(:tracker_kind, kind(&Aiur.Config.tracker_kind/0, "tracker unavailable"))
     |> assign(:agent_kind, kind(&Aiur.Config.agent_kind/0, "agent unavailable"))}
  end

  @impl true
  def handle_event("toggle-nav", _params, socket), do: {:noreply, NavState.toggle(socket)}

  def handle_event("restore-nav", %{"collapsed" => collapsed}, socket),
    do: {:noreply, NavState.restore(socket, collapsed)}

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
      <section id="streamdeck-page" class="sd-stage" aria-label="Stream Deck emulator">
        <div class="sd-device" role="group" aria-label="Stream Deck + control surface">
          <header class="sd-brand">
            <span class="sd-brand-mark" aria-hidden="true"><i></i><i></i><i></i><i></i></span>
            <span>STREAM DECK</span>
          </header>

          <div id="sd-keys" class="sd-keys" role="list" aria-label="Agent keys">
            <article
              :for={key <- @keys}
              class={["sd-key", key.empty? && "is-empty", "st-#{key.bucket}"]}
              role={!key.empty? && "listitem"}
              aria-hidden={to_string(key.empty?)}
              data-streamdeck-key={key.slot}
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
                  <span class="sd-progress" aria-label={"#{key.progress}% complete"}><i style={"width: #{key.progress}%"}></i></span>
                </div>
              </div>
            </article>
          </div>

          <div id="sd-screen" class="sd-screen" role="group" aria-label="Touch strip">
            <div :for={segment <- @screen} class={["sd-screen-segment", segment.live? && "is-live"]}>
              <span :if={segment.label == "Claude"} class="sd-mic" aria-hidden="true"></span>
              <span class="sd-screen-icon" aria-hidden="true">{segment.icon}</span>
              <span>{segment.label}</span>
            </div>
          </div>

          <div class="sd-well">
            <div id="sd-knobs" class="sd-knobs" role="group" aria-label="Control dials">
              <div :for={knob <- @knobs} class="sd-knob-wrap">
                <div class="sd-knob" style={"--a: #{knob.angle}deg"} role="img" aria-label={"#{knob.label}: #{knob.value}"}>
                  <span class="sd-knob-marker" aria-hidden="true"></span>
                  <span class="sd-knob-inner">{knob.value}</span>
                </div>
                <span>{knob.label}</span>
              </div>
            </div>
          </div>
        </div>
      </section>
    </DashboardShell.dashboard_shell>
    """
  end

  # This complete fixture is intentionally descriptor-shaped. #1350 replaces
  # its source with the shared pure key-content model once it is available.
  defp preview_key_descriptors do
    [
      key(1, "running", "Codex", 1352, "Build emulator", "Running", 62, priority?: true),
      key(2, "paused", "Claude", 1345, "Project grid", "Paused", 48, priority?: false),
      key(3, "stuck", "Codex", 1338, "Repair sync", "Stuck", 37, priority?: false),
      key(4, "alert", "Claude", 1331, "Review decision", "Alert", 81, priority?: true),
      key(5, "queued", "Codex", 1350, "Key model", "Queued", 0, priority?: false, dependency: "Blocked"),
      empty_key(6),
      empty_key(7),
      empty_key(8)
    ]
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
      empty?: false
    }
  end

  defp empty_key(slot), do: %{slot: slot, bucket: "empty", empty?: true}

  defp screen_descriptors do
    [
      %{label: "Summary", icon: "▤", live?: false},
      %{label: "Claude", icon: "◒", live?: false},
      %{label: "Codex", icon: "◇", live?: true},
      %{label: "Pager", icon: "›", live?: false}
    ]
  end

  defp knob_descriptors do
    [
      %{label: "Focus", value: "62", angle: 138},
      %{label: "Volume", value: "74", angle: 174},
      %{label: "Speed", value: "48", angle: 78},
      %{label: "Page", value: "01", angle: 36}
    ]
  end

  defp kind(provider, fallback) do
    case provider.() do
      value when is_atom(value) or is_binary(value) -> to_string(value)
      _ -> fallback
    end
  rescue
    _e -> fallback
  end
end
