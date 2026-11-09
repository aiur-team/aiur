defmodule AiurWeb.AnalyticsLive do
  @moduledoc """
  Authenticated, read-only LiveView for latest-run utilization. It derives every
  chart from the durable `Aiur.RunTelemetry` stream via the analytics
  `Presenter`, and renders them as inline SVG inside the Operator Control Center
  shell. Legend, sort, and time-range interactions are plain LiveView events — no client-side charting.
  """

  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}
  require Logger

  alias AiurWeb.AnalyticsLive.Panels

  alias AiurWeb.OperatorControlCenter.{
    AwaitingCommands,
    DashboardShell,
    NavState,
    Overview,
    RouteRegistry
  }

  alias AiurWeb.OperatorControlCenter.Analytics.{Charts, ConcurrencyCoverage, Loading, Runtime, ScopeResolver, SourceInfo, Styles}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> DashboardShell.mount()
     |> AwaitingCommands.mount(connected?(socket))
     |> assign(:current_route, RouteRegistry.current_route(:analytics))
     |> assign(:analytics, AiurWeb.Presenter.analytics_navigation())
     |> assign(:tracker_kind, kind(&Aiur.Config.tracker_kind/0, "tracker unavailable"))
     |> assign(:agent_kind, kind(&Aiur.Config.agent_kind/0, "agent unavailable"))
     |> assign(:capture_enabled?, Aiur.RunTelemetry.telemetry_enabled?())
     |> assign(:range, :run)
     |> assign(:sort, :cpu)
     |> assign(:time_domain, nil)
     |> assign(:analytics_scope, :session)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = socket |> assign(:analytics_scope, analytics_scope(Map.get(params, "build_order"))) |> load_model()
    {:noreply, socket}
  end

  @impl true
  defdelegate handle_info(message, socket), to: Runtime

  @impl true
  def handle_async(:analytics_model, {:ok, {result, rtk}}, socket), do: accept_analytics_result(socket, result, rtk)

  def handle_async(:analytics_model, {:exit, reason}, socket) do
    if socket.assigns[:analytics_refreshing?] || socket.assigns[:analytics_timed_out?] do
      {:noreply, assign(socket, :analytics_refreshing?, false)}
    else
      Logger.warning("Analytics loading failed: #{inspect(reason)}")
      handle_async(:analytics_model, {:ok, {{:unavailable, :error}, %{state: :absent, title: "Compression unavailable", message: "Analytics loading failed."}}}, socket)
    end
  end

  def handle_async(:analytics_model, _result, socket), do: {:noreply, socket}

  defp chart_model(model, {start_ms, end_ms}) when is_integer(start_ms) and is_integer(end_ms),
    do: Charts.with_exact_time_domain(model, {start_ms, end_ms}, boundary_samples: false)

  defp chart_model(model, _domain), do: model

  defp accept_analytics_result(socket, result, rtk) do
    now = DateTime.utc_now()
    if socket.assigns[:analytics_cache_key], do: Runtime.cache_result(socket.assigns.analytics_cache_key, result)
    socket = assign(socket, :rtk, rtk)

    socket =
      case result do
        {:ok, model} ->
          domain = Charts.normalize_time_domain(model, socket.assigns.time_domain)

          socket
          |> assign(
            model: model,
            chart_model: chart_model(model, domain),
            provider_spend: Panels.provider_spend(socket, model.source_boot_id),
            selected: MapSet.new(model.actors, & &1.key),
            unavailable: nil,
            source: SourceInfo.for_model(model, now),
            analytics_refreshing?: false,
            now: now
          )
          |> assign_time_domain(domain)

        {:unavailable, reason} ->
          assign(socket,
            model: nil,
            chart_model: nil,
            provider_spend: %{state: :unavailable},
            time_domain: nil,
            selected: MapSet.new(),
            source: nil,
            unavailable: reason,
            analytics_refreshing?: false,
            now: now
          )
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle-global-pause", _params, socket), do: {:noreply, DashboardShell.toggle_pause(socket)}
  def handle_event("toggle-nav", _params, socket), do: {:noreply, NavState.toggle(socket)}

  def handle_event("restore-nav", %{"collapsed" => collapsed}, socket),
    do: {:noreply, NavState.restore(socket, collapsed)}

  @impl true
  def handle_event("toggle_unit", %{"key" => key}, socket) do
    selected = toggle(socket.assigns.selected, key)
    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("select_all", _params, socket) do
    all =
      if socket.assigns.model,
        do: MapSet.new(socket.assigns.model.actors, & &1.key),
        else: MapSet.new()

    {:noreply, assign(socket, :selected, all)}
  end

  def handle_event("select_none", _params, socket) do
    {:noreply, assign(socket, :selected, MapSet.new())}
  end

  def handle_event("sort", %{"by" => by}, socket) do
    {:noreply, assign(socket, :sort, sort_atom(by))}
  end

  def handle_event("range", %{"range" => range}, socket) do
    {:noreply, socket |> assign(:range, range_atom(range)) |> assign(:time_domain, nil) |> load_model()}
  end

  def handle_event("time-domain", params, %{assigns: %{model: model}} = socket)
      when not is_nil(model) do
    domain = Charts.normalize_time_domain(model, {Map.get(params, "t0"), Map.get(params, "t1")})
    {:noreply, assign_time_domain(socket, domain)}
  end

  def handle_event("time-domain", _params, socket), do: {:noreply, socket}

  def handle_event("reset-time-domain", _params, socket) do
    {:noreply, assign_time_domain(socket, nil)}
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
      nav_counts={@nav_counts} pause_state={DashboardShell.pause_state(assigns)}
    >
      <:banner>
        <Overview.decisions_banner retained_counts={@retained_counts} navigate />
      </:banner>
      {Phoenix.HTML.raw("<style>" <> Styles.css() <> "</style>")}
      <section id="analytics-page" class="analytics-root" aria-label="Run analytics">
        <p :if={!@capture_enabled?} id="analytics-capture-off" role="status" class="an-empty">
          Analytics capture is off (observability.telemetry_enabled: false). Experiments will have no data for this period.
        </p>
        <Loading.state
          state={@unavailable}
          elapsed_seconds={@analytics_load_elapsed_seconds}
          timeout_seconds={@analytics_load_timeout_seconds}
          refreshing?={@analytics_refreshing?}
          refresh_timed_out?={@analytics_timed_out?}
        />
        <div :if={@unavailable && @unavailable not in [:loading, :timeout]} class="an-empty" data-empty-reason={@unavailable}>
          <div :if={@unavailable == :no_telemetry}>
            <p><b>No run telemetry to analyze yet.</b></p>
            <p>These charts are derived from the durable run-telemetry stream and appear after it records agent or ticket activity.</p>
          </div>
          <div :if={@unavailable in [:retained_unreadable, :retained_scan_limited]}>
            <p><b>{if @unavailable == :retained_scan_limited, do: "Retained run telemetry is too large to scan within the page budget.", else: "Retained run telemetry could not be read."}</b></p>
            <p>{if @unavailable == :retained_scan_limited, do: "The retained summaries are readable, but none fit within the bounded scan. Try again after the summaries have been reduced.", else: "A prior run recorded telemetry, but its retained summary cannot be decoded. Check the run-summary files under the analytics state node."}</p>
          </div>
          <div :if={@unavailable == :error}>
            <p><b>Run telemetry is unavailable.</b></p>
            <p>The durable run-telemetry stream could not be analyzed right now.</p>
          </div>
        </div>
        <div :if={!@unavailable} class="an-controls">
          <div>
            <span class="an-scope">Scope: <b>{Panels.scope_label(@analytics_scope)}</b></span>
            <p class="an-scope-note">
              {Panels.scope_note(@analytics_scope, @model)}
            </p>
            <p :if={@source} class="an-source" data-source-kind={@source.kind} title={Panels.source_title(@source)}>
              Source: <b>{Panels.source_kind_label(@source.kind)}</b>
              <span :if={@source.boot_id} class="an-source-boot"> · boot {Panels.short_boot(@source.boot_id)}</span>
              <span class="an-source-age"> · {Panels.age_label(@source.age_ms)}</span><span :if={@model && Map.get(@model, :retained_runs)}> · {@model.retained_runs.included} of {@model.retained_runs.total} retained runs</span><span :if={@model && get_in(@model, [:retained_runs, :skipped_newer]) not in [nil, 0]}> · Newer retained runs skipped: {@model.retained_runs.skipped_newer} (45 MiB scan budget)</span><span :if={@model && get_in(@model, [:retained_runs, :skipped_large]) not in [nil, 0] && get_in(@model, [:retained_runs, :skipped_newer]) in [nil, 0]}> · {@model.retained_runs.skipped_large} other retained runs omitted by the 45 MiB scan budget</span>
            </p>
          </div>
          <div class="an-seg" role="group" aria-label="Time range">
            <button type="button" class={[@range == :run && "on"]} phx-click="range" phx-value-range="run">Run</button>
            <button type="button" class={[@range == :full && "on"]} phx-click="range" phx-value-range="full">Full log</button>
          </div>
        </div>
        <div :if={!is_nil(@time_domain)} class="an-zoombar" role="status">
          <span>Zoomed to {Charts.time_domain_label(@chart_model, @time_domain)}</span>
          <button type="button" phx-click="reset-time-domain">Reset</button>
        </div>

        <div :if={!@unavailable} class="an-kpis">
          <div :for={k <- Panels.kpi_items(@model, @provider_spend, @source.kind, @analytics_scope)} class={["an-kpi", k.tone]}>
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
            <div id="analytics-gantt-chart" class="an-chart" phx-hook="TimeBrush">{Phoenix.HTML.raw(Charts.gantt(@chart_model))}</div>
          </section>

          <section class="an-card wide">
            <div class="an-card-head">
              <div>
                <h3 class="an-card-title">Per-unit CPU</h3>
                <p class="an-card-sub">Stacked CPU across the daemon/executor baseline and each unit ticket. The ceiling line marks machine capacity.</p>
              </div>
            </div>
            <div id="analytics-cpu-chart" class="an-chart" phx-hook="TimeBrush">{Phoenix.HTML.raw(Charts.cpu_stack(@chart_model, @selected))}</div>
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
                <p :if={ConcurrencyCoverage.partial_reason(@model, @analytics_scope)} id="analytics-concurrency-coverage" class="an-card-sub" role="status">{ConcurrencyCoverage.partial_reason(@model, @analytics_scope)}</p>
              </div>
            </div>
            <div id="analytics-concurrency-chart" class="an-chart" phx-hook="TimeBrush">{if ConcurrencyCoverage.unknown?(@model, @analytics_scope), do: ConcurrencyCoverage.chart_unknown_label(@model, @analytics_scope), else: Phoenix.HTML.raw(Charts.concurrency(@chart_model))}</div>
          </section>

          <section class="an-card wide">
            <div class="an-card-head">
              <div>
                <h3 class="an-card-title">Fleet-wide build pressure</h3>
                <p class="an-card-sub">Whole-host occupied agents, measured capacities, active and queued builds, oldest live wait, and the binding admission signal. Gaps are unavailable evidence, never zero.</p>
              </div>
            </div>
            <div id="analytics-pressure-chart" class="an-chart" phx-hook="TimeBrush">{Phoenix.HTML.raw(Charts.fleet_pressure(@chart_model))}</div>
            <div class="an-legend" aria-label="Fleet pressure source states">
              <span>Source state:</span> <span>current</span> · <span>stale fleet</span> · <span>degraded build</span> · <span>partial</span> · <span>empty</span>
            </div>
            <details class="data-table">
              <summary>Accessible fleet pressure data</summary>
              <div class="table-scroll">
                <table id="analytics-pressure-table">
                  <caption>Timestamped whole-host fleet and build-pressure samples</caption>
                  <thead><tr><th>Sample time</th><th>State</th><th>Fleet source</th><th>Fleet observed</th><th>Build source</th><th>Build observed</th><th>Binding</th><th>Load</th><th>Occupied</th><th>Configured / max / effective</th><th>Build capacity</th><th>Active / queued builds</th><th>Oldest wait</th></tr></thead>
                  <tbody>
                    <tr :for={sample <- @chart_model.series}>
                      <td>{Panels.pressure_time(sample.t_ms)}</td>
                      <td>{Panels.pressure_value(sample.pressure_state)}</td>
                      <td>{Panels.pressure_value(Map.get(sample, :fleet_capacity_status))}</td>
                      <td>{Panels.pressure_time(Map.get(sample, :fleet_capacity_observed_at_ms))}</td>
                      <td>{Panels.pressure_value(Map.get(sample, :build_gate_status))}</td>
                      <td>{Panels.pressure_time(Map.get(sample, :build_gate_observed_at_ms))}</td>
                      <td>{Panels.pressure_value(Map.get(sample, :fleet_admission_signal))}</td>
                      <td>{Panels.pressure_load(Map.get(sample, :fleet_load), Map.get(sample, :fleet_load_threshold))}</td>
                      <td>{Panels.pressure_value(Map.get(sample, :fleet_agents_occupied))}</td>
                      <td>{Panels.pressure_values(sample, [:fleet_agents_configured, :fleet_agents_max, :fleet_agents_effective])}</td>
                      <td>{Panels.pressure_value(Map.get(sample, :build_gate_capacity))}</td>
                      <td>{Panels.pressure_values(sample, [:build_gate_active, :build_gate_queued])}</td>
                      <td>{Panels.pressure_seconds(Map.get(sample, :build_queue_oldest_wait_seconds))}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </details>
          </section>

          <section class="an-card">
            <div class="an-card-head">
              <div>
                <h3 class="an-card-title">Memory over run</h3>
                <p class="an-card-sub">Aggregate resident memory against the host ceiling — the real limiter on running more units.</p>
              </div>
            </div>
            <div id="analytics-memory-chart" class="an-chart" phx-hook="TimeBrush">{Phoenix.HTML.raw(Charts.memory(@chart_model))}</div>
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
            <div id="analytics-burnup-chart" class="an-chart" phx-hook="TimeBrush">{Phoenix.HTML.raw(Charts.burnup(@chart_model))}</div>
          </section>

          <section class="an-card wide">
            <div class="an-card-head">
              <div>
                <h3 class="an-card-title">Complexity breakdown</h3>
                <p class="an-card-sub">Ticket count by dispatch-time complexity tier with average wall-clock.</p>
              </div>
            </div>
            <div class="an-chart">{Phoenix.HTML.raw(Charts.complexity_breakdown(@model))}</div>
          </section>

          <section class="an-card" aria-labelledby="analytics-rtk-title">
            <div class="an-card-head">
              <div>
                <h3 class="an-card-title" id="analytics-rtk-title">Agent output compression</h3>
                <p class="an-card-sub">
                  Tokens rtk stripped from shell output before an agent read it. Counts commands rtk actually filtered, not every command agents ran.
                </p>
              </div>
            </div>
            <div :if={@rtk.state == :ok} class="an-chart an-rtk">
              <div class="an-rtk-figure">
                <span class="an-rtk-val">{@rtk.savings_pct}%</span>
                <span class="an-rtk-label">of filtered output removed</span>
              </div>
              <dl class="an-rtk-facts">
                <div>
                  <dt>Tokens saved</dt>
                  <dd>{@rtk.saved_tokens}</dd>
                </div>
                <div>
                  <dt>Before / after</dt>
                  <dd>{@rtk.input_tokens} → {@rtk.output_tokens}</dd>
                </div>
                <div>
                  <dt>Commands filtered</dt>
                  <dd>{@rtk.commands}</dd>
                </div>
              </dl>
            </div>
            <div :if={@rtk.state != :ok} class="an-empty" role="status">
              <p><b>{@rtk.title}</b></p>
              <p>{@rtk.message}</p>
            </div>
          </section>
        </div>
      </section>
    </DashboardShell.dashboard_shell>
    """
  end

  defp load_model(socket), do: Runtime.load(socket, ScopeResolver.telemetry_opts(socket.assigns.analytics_scope), &Panels.rtk_panel/0)

  defp assign_time_domain(%{assigns: %{model: model}} = socket, domain) when not is_nil(model) do
    assign(socket, time_domain: domain, chart_model: Charts.with_time_domain(model, domain))
  end

  defp assign_time_domain(socket, _domain), do: socket

  defp analytics_scope(root_number), do: ScopeResolver.resolve(root_number)

  defp toggle(set, key) do
    if MapSet.member?(set, key), do: MapSet.delete(set, key), else: MapSet.put(set, key)
  end

  defp sort_atom("peakcpu"), do: :peakcpu
  defp sort_atom("mem"), do: :mem
  defp sort_atom(_cpu), do: :cpu

  defp range_atom("full"), do: :full
  defp range_atom(_run), do: :run

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
