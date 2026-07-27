defmodule AiurWeb.AnalyticsLive do
  @moduledoc """
  Authenticated, read-only LiveView for live run utilization. It derives every
  chart from the durable `Aiur.RunTelemetry` stream via the analytics
  `Presenter`, and renders them as inline SVG inside the Operator Control Center
  shell. Legend, sort, and time-range interactions are plain LiveView events —
  no client-side charting.
  """

  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias AiurWeb.OperatorControlCenter.Analytics.{Charts, Presenter, Styles}
  alias AiurWeb.OperatorControlCenter.{DashboardShell, NavState, RouteRegistry}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> NavState.assign_nav()
     |> assign(:current_route, RouteRegistry.current_route(:analytics))
     |> assign(:analytics, AiurWeb.Presenter.analytics_navigation())
     |> assign(:tracker_kind, kind(&Aiur.Config.tracker_kind/0, "tracker unavailable"))
     |> assign(:agent_kind, kind(&Aiur.Config.agent_kind/0, "agent unavailable"))
     |> assign(:range, :run)
     |> assign(:sort, :cpu)
     |> load_model()}
  end

  @impl true
  def handle_event("toggle-nav", _params, socket), do: {:noreply, NavState.toggle(socket)}

  @impl true
  def handle_event("restore-nav", %{"collapsed" => collapsed}, socket),
    do: {:noreply, NavState.restore(socket, collapsed)}

  @impl true
  def handle_event("toggle_unit", %{"key" => key}, socket) do
    selected = toggle(socket.assigns.selected, key)
    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("select_all", _params, socket) do
    all = if socket.assigns.model, do: MapSet.new(socket.assigns.model.actors, & &1.key), else: MapSet.new()
    {:noreply, assign(socket, :selected, all)}
  end

  def handle_event("select_none", _params, socket) do
    {:noreply, assign(socket, :selected, MapSet.new())}
  end

  def handle_event("sort", %{"by" => by}, socket) do
    {:noreply, assign(socket, :sort, sort_atom(by))}
  end

  def handle_event("range", %{"range" => range}, socket) do
    {:noreply, socket |> assign(:range, range_atom(range)) |> load_model()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <DashboardShell.dashboard_shell
      route={@current_route}
      routes={RouteRegistry.routes(@analytics)}
      tracker_kind={@tracker_kind}
      agent_kind={@agent_kind}
      nav_collapsed={@nav_collapsed}
    >
      {Phoenix.HTML.raw("<style>" <> Styles.css() <> "</style>")}

      <section id="analytics-page" class="analytics-root" aria-label="Run analytics">
        <div :if={@unavailable} class="an-empty">
          <p><b>No run telemetry to analyze yet.</b></p>
          <p>These charts are derived from the durable run-telemetry stream. Start a run with telemetry enabled and this view will populate on the next visit.</p>
        </div>

        <div :if={!@unavailable} class="an-controls">
          <div>
            <span class="an-scope">Scope: <b>this session</b></span>
            <p class="an-scope-note">
              The current live run only. For a whole Build Order's history across many sessions, open its Build Order page.
            </p>
          </div>
          <div class="an-seg" role="group" aria-label="Time range">
            <button type="button" class={[@range == :run && "on"]} phx-click="range" phx-value-range="run">Run</button>
            <button type="button" class={[@range == :full && "on"]} phx-click="range" phx-value-range="full">Full log</button>
          </div>
        </div>

        <div :if={!@unavailable} class="an-kpis">
          <div :for={k <- kpi_items(@model)} class={["an-kpi", k.tone]}>
            <span class="an-kpi-label">{k.label}</span>
            <span class="an-kpi-val">{k.val}</span>
            <span class="an-kpi-sub">{k.sub}</span>
          </div>
        </div>

        <div :if={!@unavailable} class="an-grid">
          <section class="an-card wide scroll">
            <div class="an-card-head">
              <div>
                <h3 class="an-card-title">Tickets</h3>
                <p class="an-card-sub">Lifecycle per ticket — the wait rail into a work bar coloured by status, capped by an end marker.</p>
              </div>
            </div>
            <div class="an-chart">{Phoenix.HTML.raw(Charts.gantt(@model))}</div>
          </section>

          <section class="an-card wide">
            <div class="an-card-head">
              <div>
                <h3 class="an-card-title">Per-unit CPU</h3>
                <p class="an-card-sub">Stacked CPU across the daemon/executor baseline and each unit ticket. The dashed line is the machine ceiling.</p>
              </div>
            </div>
            <div class="an-chart">{Phoenix.HTML.raw(Charts.cpu_stack(@model, @selected))}</div>
            <div class="an-legend">
              <div class="an-legend-head">
                <span class="an-legend-title">Units</span>
                <div class="an-legend-acts">
                  <button type="button" class="an-lg-btn" phx-click="select_all">All</button>
                  <button type="button" class="an-lg-btn" phx-click="select_none">None</button>
                </div>
              </div>
              <div class="an-chips">
                <button
                  :for={a <- @model.actors}
                  type="button"
                  class={["an-chip", MapSet.member?(@selected, a.key) && "on"]}
                  phx-click="toggle_unit"
                  phx-value-key={a.key}
                  title={a.label}
                >
                  <i style={"background:var(--an-s#{a.color_i})"}></i>{a.label}
                </button>
              </div>
            </div>
          </section>

          <section class="an-card">
            <div class="an-card-head">
              <div>
                <h3 class="an-card-title">Concurrency vs cap</h3>
                <p class="an-card-sub">Active units against the cap. The shaded band above the line is wasted capacity.</p>
              </div>
            </div>
            <div class="an-chart">{Phoenix.HTML.raw(Charts.concurrency(@model))}</div>
          </section>

          <section class="an-card">
            <div class="an-card-head">
              <div>
                <h3 class="an-card-title">Memory over run</h3>
                <p class="an-card-sub">Aggregate resident memory against the host ceiling — the real limiter on running more units.</p>
              </div>
            </div>
            <div class="an-chart">{Phoenix.HTML.raw(Charts.memory(@model))}</div>
          </section>

          <section class="an-card scroll">
            <div class="an-card-head">
              <div>
                <h3 class="an-card-title">Cost per ticket</h3>
                <p class="an-card-sub">CPU-seconds burned per unit. Toggle to rank by peak CPU or peak memory.</p>
              </div>
              <div class="an-seg" role="group" aria-label="Cost metric">
                <button type="button" class={[@sort == :cpu && "on"]} phx-click="sort" phx-value-by="cpu">CPU·s</button>
                <button type="button" class={[@sort == :peakcpu && "on"]} phx-click="sort" phx-value-by="peakcpu">Peak CPU</button>
                <button type="button" class={[@sort == :mem && "on"]} phx-click="sort" phx-value-by="mem">Peak mem</button>
              </div>
            </div>
            <div class="an-chart">{Phoenix.HTML.raw(Charts.cost(@model, @selected, @sort))}</div>
          </section>

          <section class="an-card">
            <div class="an-card-head">
              <div>
                <h3 class="an-card-title">Burn-up</h3>
                <p class="an-card-sub">Cumulative tickets merged against total scope over the run.</p>
              </div>
            </div>
            <div class="an-chart">{Phoenix.HTML.raw(Charts.burnup(@model))}</div>
          </section>
        </div>
      </section>
    </DashboardShell.dashboard_shell>
    """
  end

  defp load_model(socket) do
    now = DateTime.utc_now()

    opts = [
      range: socket.assigns.range,
      session: :current,
      telemetry_file: Application.get_env(:aiur, :analytics_telemetry_file)
    ]

    case Presenter.load(opts) do
      {:ok, model} ->
        assign(socket, model: model, selected: MapSet.new(model.actors, & &1.key), unavailable: nil, now: now)

      {:unavailable, reason} ->
        assign(socket, model: nil, selected: MapSet.new(), unavailable: reason, now: now)
    end
  end

  defp kpi_items(model) do
    k = model.kpis

    [
      %{label: "Peak concurrency", val: k.peak_conc, sub: "#{k.conc_now} now / #{k.cap} cap", tone: nil},
      %{label: "Mean utilization", val: "#{k.mean_util_pct}%", sub: "of #{model.cores} cores", tone: nil},
      %{label: "Memory headroom", val: "#{k.mem_headroom_pct}%", sub: "#{gb(k.mem_now_bytes)} / #{gb(model.host_mem_bytes)}", tone: nil},
      %{label: "PRs merged", val: k.merged, sub: "this run", tone: nil},
      %{label: "Tickets done", val: "#{k.done} / #{k.total}", sub: "#{k.done_pct}% complete", tone: nil},
      %{label: "Wasted capacity", val: "#{k.wasted_slot_hours}h", sub: "idle unit-slots", tone: "block"}
    ]
  end

  defp toggle(set, key) do
    if MapSet.member?(set, key), do: MapSet.delete(set, key), else: MapSet.put(set, key)
  end

  defp sort_atom("peakcpu"), do: :peakcpu
  defp sort_atom("mem"), do: :mem
  defp sort_atom(_cpu), do: :cpu

  defp range_atom("full"), do: :full
  defp range_atom(_run), do: :run

  defp gb(bytes) when is_number(bytes), do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"
  defp gb(_bytes), do: "0 GB"

  defp kind(provider, fallback) do
    case provider.() do
      value when is_atom(value) or is_binary(value) -> to_string(value)
      _ -> fallback
    end
  rescue
    _ -> fallback
  catch
    _, _ -> fallback
  end
end
