defmodule AiurWeb.AnalyticsLive do
  @moduledoc """
  Authenticated, read-only LiveView for live run utilization. It derives every
  chart from the durable `Aiur.RunTelemetry` stream via the analytics
  `Presenter`, and renders them as inline SVG inside the Operator Control Center
  shell. Legend, sort, and time-range interactions are plain LiveView events —
  no client-side charting.
  """

  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias AiurWeb.OperatorControlCenter.Analytics.{Charts, Presenter}
  alias AiurWeb.OperatorControlCenter.{DashboardShell, RouteRegistry}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_route, RouteRegistry.current_route(:analytics))
     |> assign(:analytics, AiurWeb.Presenter.analytics_navigation())
     |> assign(:tracker_kind, kind(&Aiur.Config.tracker_kind/0, "tracker unavailable"))
     |> assign(:agent_kind, kind(&Aiur.Config.agent_kind/0, "agent unavailable"))
     |> assign(:range, :run)
     |> assign(:sort, :cpu)
     |> load_model()}
  end

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
      now={@now}
      tracker_kind={@tracker_kind}
      agent_kind={@agent_kind}
    >
      {Phoenix.HTML.raw("<style>" <> page_css() <> "</style>")}

      <section id="analytics-page" class="analytics-root" aria-label="Run analytics">
        <div :if={@unavailable} class="an-empty">
          <p><b>No run telemetry to analyze yet.</b></p>
          <p>These charts are derived from the durable run-telemetry stream. Start a run with telemetry enabled and this view will populate on the next visit.</p>
        </div>

        <div :if={!@unavailable} class="an-controls">
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
    opts = [range: socket.assigns.range, telemetry_file: Application.get_env(:aiur, :analytics_telemetry_file)]

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

  defp page_css do
    """
    #analytics-page{
      --an-mono:"JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
      --an-s1:#3987e5;--an-s2:#008300;--an-s3:#d55181;--an-s4:#c98500;
      --an-s5:#199e70;--an-s6:#d95926;--an-s7:#9085e9;--an-s8:#e66767;
    }
    html[data-theme="light"] #analytics-page{
      --an-s1:#2a78d6;--an-s2:#008300;--an-s3:#e87ba4;--an-s4:#eda100;
      --an-s5:#1baf7a;--an-s6:#eb6834;--an-s7:#4a3aa7;--an-s8:#e34948;
    }
    .analytics-root{display:flex;flex-direction:column;gap:1rem}
    .an-controls{display:flex;justify-content:flex-end}
    .an-kpis{display:grid;grid-template-columns:repeat(6,1fr);gap:.7rem}
    .an-kpi{border:1px solid var(--line);border-radius:var(--radius);background:var(--surface);box-shadow:var(--shadow-sm);padding:.85rem .95rem;display:flex;flex-direction:column;gap:.15rem}
    .an-kpi-label{font-family:var(--an-mono);font-size:.62rem;font-weight:700;letter-spacing:.05em;text-transform:uppercase;color:var(--muted)}
    .an-kpi-val{font-family:var(--an-mono);font-size:1.5rem;font-weight:700;letter-spacing:-.02em;color:var(--fg);line-height:1.05}
    .an-kpi-sub{font-size:.72rem;color:var(--faint)}
    .an-kpi.block .an-kpi-val{color:var(--blocking-ink)}
    .an-grid{display:grid;grid-template-columns:1fr 1fr;gap:1rem;align-items:start}
    .an-card{border:1px solid var(--line);border-radius:var(--radius);background:var(--surface);box-shadow:var(--shadow-sm);padding:1rem 1.1rem .9rem;display:flex;flex-direction:column;min-width:0}
    .an-card.wide{grid-column:1 / -1}
    .an-card.scroll .an-chart{max-height:440px;overflow-y:auto;overflow-x:hidden}
    .an-card-head{display:flex;align-items:flex-start;justify-content:space-between;gap:1rem;margin-bottom:.7rem}
    .an-card-title{margin:0;font-size:.98rem;font-weight:700;color:var(--fg);letter-spacing:-.01em}
    .an-card-sub{margin:.2rem 0 0;font-size:.78rem;line-height:1.4;color:var(--muted);max-width:64ch}
    .an-chart{width:100%;min-width:0}
    .an-seg{display:inline-flex;border:1px solid var(--line);border-radius:999px;overflow:hidden;flex:none}
    .an-seg button{appearance:none;border:0;background:transparent;color:var(--muted);font-family:var(--an-mono);font-size:.68rem;font-weight:600;padding:.3rem .6rem;cursor:pointer;border-right:1px solid var(--line)}
    .an-seg button:last-child{border-right:0}
    .an-seg button.on{background:var(--accent-soft);color:var(--accent-ink)}
    .an-legend{border-top:1px solid var(--hairline);margin-top:.6rem;padding-top:.7rem}
    .an-legend-head{display:flex;align-items:center;justify-content:space-between;margin-bottom:.55rem}
    .an-legend-title{font-family:var(--an-mono);font-size:.66rem;font-weight:700;letter-spacing:.05em;text-transform:uppercase;color:var(--muted)}
    .an-legend-acts{display:flex;gap:.35rem}
    .an-lg-btn{appearance:none;border:1px solid var(--line);background:transparent;color:var(--muted);font-family:var(--an-mono);font-size:.66rem;font-weight:600;padding:.2rem .55rem;border-radius:999px;cursor:pointer}
    .an-lg-btn:hover{color:var(--fg);border-color:var(--line-strong)}
    .an-chips{display:flex;flex-wrap:wrap;gap:.3rem}
    .an-chip{display:inline-flex;align-items:center;gap:.3rem;border:1px solid var(--line);background:var(--pill-bg);color:var(--faint);font-family:var(--an-mono);font-size:.68rem;font-weight:600;padding:.16rem .42rem;border-radius:7px;cursor:pointer}
    .an-chip i{width:8px;height:8px;border-radius:2px;opacity:.35;flex:none}
    .an-chip.on{color:var(--fg);border-color:var(--line-strong)}
    .an-chip.on i{opacity:1}
    .an-chip:hover{border-color:var(--accent-line)}
    .an-empty{border:1px dashed var(--line-strong);border-radius:var(--radius);background:var(--surface);padding:2.4rem;text-align:center;color:var(--muted)}
    .an-empty b{color:var(--fg)}
    @media(max-width:1080px){.an-kpis{grid-template-columns:repeat(3,1fr)}.an-grid{grid-template-columns:1fr}.an-card.wide{grid-column:auto}}
    @media(max-width:560px){.an-kpis{grid-template-columns:repeat(2,1fr)}.an-card-head{flex-direction:column}}
    """
  end
end
