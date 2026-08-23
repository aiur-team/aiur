defmodule AiurWeb.AnalyticsLive do
  @moduledoc """
  Authenticated, read-only LiveView for latest-run utilization. It derives every
  chart from the durable `Aiur.RunTelemetry` stream via the analytics
  `Presenter`, and renders them as inline SVG inside the Operator Control Center
  shell. Legend, sort, and time-range interactions are plain LiveView events —
  no client-side charting.
  """

  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias Aiur.{PollCadence, UsageAggregate}
  alias Aiur.Usage.GroupedScopes
  alias Aiur.Usage.GroupedScopes.Scope
  alias AiurWeb.{FinancialData, FinancialDataAccess}

  alias AiurWeb.OperatorControlCenter.{
    AwaitingCommands,
    DashboardShell,
    NavState,
    Overview,
    RouteRegistry,
    UsageSummaryPresenter
  }

  alias AiurWeb.OperatorControlCenter.Analytics.{Charts, Presenter, ScopeResolver, Styles}

  @usage_summary_max_age_ms 30_000
  # Matches the CLI's freshness threshold: telemetry observed within this
  # window is "just now", anything older is shown with its elapsed age.
  @source_fresh_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> NavState.assign_nav()
     |> AwaitingCommands.mount(connected?(socket))
     |> assign(:current_route, RouteRegistry.current_route(:analytics))
     |> assign(:analytics, AiurWeb.Presenter.analytics_navigation())
     |> assign(:tracker_kind, kind(&Aiur.Config.tracker_kind/0, "tracker unavailable"))
     |> assign(:agent_kind, kind(&Aiur.Config.agent_kind/0, "agent unavailable"))
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
  def handle_info({:decision_changed, _decision_id, _version}, socket),
    do: {:noreply, AwaitingCommands.refresh(socket)}

  def handle_info(:awaiting_commands_tick, socket), do: {:noreply, AwaitingCommands.tick(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

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
      nav_counts={@nav_counts}
    >
      <:banner>
        <Overview.decisions_banner retained_counts={@retained_counts} navigate />
      </:banner>

      {Phoenix.HTML.raw("<style>" <> Styles.css() <> "</style>")}

      <section id="analytics-page" class="analytics-root" aria-label="Run analytics">
        <div :if={@unavailable} class="an-empty" data-empty-reason={@unavailable}>
          <div :if={@unavailable == :no_telemetry}>
            <p><b>No run telemetry to analyze yet.</b></p>
            <p>These charts are derived from the durable run-telemetry stream and appear after it records agent or ticket activity.</p>
          </div>
          <div :if={@unavailable == :retained_unreadable}>
            <p><b>Retained run telemetry could not be read.</b></p>
            <p>A prior run recorded telemetry, but its retained summary cannot be decoded. Check the run-summary files under the analytics state node.</p>
          </div>
          <div :if={@unavailable == :error}>
            <p><b>Run telemetry is unavailable.</b></p>
            <p>The durable run-telemetry stream could not be analyzed right now.</p>
          </div>
        </div>

        <div :if={!@unavailable} class="an-controls">
          <div>
            <span class="an-scope">Scope: <b>{scope_label(@analytics_scope)}</b></span>
            <p class="an-scope-note">
              {scope_note(@analytics_scope)}
            </p>
            <p :if={@source} class="an-source" data-source-kind={@source.kind} title={source_title(@source)}>
              Source: <b>{source_kind_label(@source.kind)}</b>
              <span :if={@source.boot_id} class="an-source-boot"> · boot {short_boot(@source.boot_id)}</span>
              <span class="an-source-age"> · {age_label(@source.age_ms)}</span>
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
          <div :for={k <- kpi_items(@model, @provider_spend)} class={["an-kpi", k.tone]}>
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
              </div>
            </div>
            <div id="analytics-concurrency-chart" class="an-chart" phx-hook="TimeBrush">{Phoenix.HTML.raw(Charts.concurrency(@chart_model))}</div>
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
                      <td>{pressure_time(sample.t_ms)}</td>
                      <td>{pressure_value(sample.pressure_state)}</td>
                      <td>{pressure_value(Map.get(sample, :fleet_capacity_status))}</td>
                      <td>{pressure_time(Map.get(sample, :fleet_capacity_observed_at_ms))}</td>
                      <td>{pressure_value(Map.get(sample, :build_gate_status))}</td>
                      <td>{pressure_time(Map.get(sample, :build_gate_observed_at_ms))}</td>
                      <td>{pressure_value(Map.get(sample, :fleet_admission_signal))}</td>
                      <td>{pressure_load(Map.get(sample, :fleet_load), Map.get(sample, :fleet_load_threshold))}</td>
                      <td>{pressure_value(Map.get(sample, :fleet_agents_occupied))}</td>
                      <td>{pressure_values(sample, [:fleet_agents_configured, :fleet_agents_max, :fleet_agents_effective])}</td>
                      <td>{pressure_value(Map.get(sample, :build_gate_capacity))}</td>
                      <td>{pressure_values(sample, [:build_gate_active, :build_gate_queued])}</td>
                      <td>{pressure_seconds(Map.get(sample, :build_queue_oldest_wait_seconds))}</td>
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
        </div>
      </section>
    </DashboardShell.dashboard_shell>
    """
  end

  defp load_model(socket) do
    now = DateTime.utc_now()

    # The Full-log range spans every boot: the current boot stays a live bounded
    # tail read and prior boots come from materialized run summaries (falling
    # back to a full parse before the first materialization).
    session = if socket.assigns.range == :full, do: :cross, else: :current

    opts =
      [
        range: socket.assigns.range,
        session: session,
        telemetry_file: Application.get_env(:aiur, :analytics_telemetry_file),
        orchestrator: AiurWeb.Endpoint.config(:orchestrator) || Aiur.Orchestrator,
        snapshot_timeout_ms: PollCadence.snapshot_tolerance_ms(AiurWeb.Endpoint.config(:snapshot_timeout_ms) || 15_000)
      ] ++ ScopeResolver.telemetry_opts(socket.assigns.analytics_scope)

    case Presenter.load(opts) do
      {:ok, model} ->
        domain = Charts.normalize_time_domain(model, socket.assigns.time_domain)

        socket
        |> assign(
          model: model,
          provider_spend: provider_spend(socket, model.source_boot_id),
          selected: MapSet.new(model.actors, & &1.key),
          unavailable: nil,
          source: source_info(model, now),
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
          now: now
        )
    end
  end

  defp assign_time_domain(%{assigns: %{model: model}} = socket, domain) when not is_nil(model) do
    assign(socket, time_domain: domain, chart_model: Charts.with_time_domain(model, domain))
  end

  defp assign_time_domain(socket, _domain), do: socket

  defp kpi_items(model, provider_spend) do
    k = model.kpis

    [
      %{
        label: "Peak concurrency",
        val: k.peak_conc,
        sub: "#{k.conc_now} now / #{Presenter.cap_label(model)}",
        tone: nil
      },
      %{
        label: "Mean utilization",
        val: "#{k.mean_util_pct}%",
        sub: "of #{model.cores} cores",
        tone: nil
      },
      %{
        label: "Memory headroom",
        val: "#{k.mem_headroom_pct}%",
        sub: "#{gb(k.mem_now_bytes)} / #{gb(model.host_mem_bytes)}",
        tone: nil
      },
      %{label: "PRs merged", val: k.merged, sub: "this run", tone: nil},
      %{
        label: "Tickets done",
        val: "#{k.done} / #{k.total}",
        sub: "#{k.done_pct}% complete",
        tone: nil
      },
      provider_spend_item(provider_spend),
      %{
        label: "Wasted capacity",
        val: Presenter.wasted_slot_hours_label(k.wasted_slot_hours),
        sub: "idle unit-slots",
        tone: "block"
      }
    ]
  end

  defp provider_spend_item(%{state: :available, amount: amount, source: source}),
    do: %{label: "Provider spend", val: amount, sub: source, tone: nil}

  defp provider_spend_item(%{state: :locked}),
    do: %{label: "Provider spend", val: "Locked", sub: "financial access required", tone: nil}

  defp provider_spend_item(_other),
    do: %{label: "Provider spend", val: "—", sub: "not available", tone: nil}

  # Financial data stays behind the same per-connection capability gate used by
  # the Build Order usage summary. The analytics page receives a display-only
  # provider estimate, never aggregate cells or an unscoped raw total.
  defp provider_spend(socket, source_boot_id) do
    case {connected?(socket), authorized_context(socket)} do
      {true, {:ok, context}} -> load_provider_spend(context, socket.assigns.analytics_scope, source_boot_id)
      {_connected, :locked} -> %{state: :locked}
      {false, {:ok, _context}} -> %{state: :loading}
    end
  rescue
    _error -> %{state: :unavailable}
  catch
    _kind, _reason -> %{state: :unavailable}
  end

  defp load_provider_spend(context, analytics_scope, source_boot_id) do
    usage_aggregate = usage_aggregate_source()

    with {:ok, scope} <- ScopeResolver.usage_scope(analytics_scope, source_boot_id),
         {:ok, snapshot} <-
           FinancialData.fetch_usage_grouping(
             FinancialData,
             context,
             {Scope.public(scope), usage_aggregate_generation(usage_aggregate)},
             @usage_summary_max_age_ms,
             fn ->
               usage_aggregate.cells_snapshot() |> GroupedScopes.project(scope, currency: "USD")
             end
           ) do
      snapshot |> UsageSummaryPresenter.present() |> provider_spend_view()
    else
      _other -> %{state: :unavailable}
    end
  end

  defp provider_spend_view(%{state: state, provider_reported: %{by_currency: entries}})
       when state in [:ready, :partial, :stale] do
    case entries do
      [] ->
        %{state: :unavailable}

      _entries ->
        %{
          state: :available,
          amount: Enum.map_join(entries, ", ", &"#{&1.amount} #{&1.currency}"),
          source: "provider-reported estimate"
        }
    end
  end

  defp provider_spend_view(_view), do: %{state: :unavailable}

  defp analytics_scope(root_number), do: ScopeResolver.resolve(root_number)

  defp scope_label(%{kind: :build_order, root_number: root_number}), do: "Build Order ##{root_number}, latest run"
  defp scope_label(:session), do: "latest run"
  defp scope_label(:unavailable), do: "selected Build Order unavailable"

  defp scope_note(%{kind: :build_order}), do: "Only the selected Build Order's typed members in the latest run with telemetry."
  defp scope_note(:session), do: "The latest run with telemetry. Add a Build Order selection to scope this page to its members."
  defp scope_note(:unavailable), do: "The selected Build Order could not provide a valid member graph."

  # The rendered charts can come from the live boot or from a retained prior
  # run (the restart fallback). The source line makes which one visible so a
  # run that ended an hour ago is never presented as the current boot, and so
  # the cutover when a fresh boot takes over is not silent.
  defp source_info(model, now) do
    current = safe_boot_id()
    boot_id = Map.get(model, :source_boot_id)
    observed_at = parse_observed(Map.get(model, :source_observed_at))
    age_ms = if observed_at, do: max(DateTime.diff(now, observed_at, :millisecond), 0), else: nil

    %{
      kind: source_kind(boot_id, current),
      boot_id: boot_id,
      observed_at: observed_at,
      age_ms: age_ms
    }
  end

  defp source_kind(boot_id, current) when is_binary(boot_id) and boot_id != "" and boot_id == current, do: :live
  defp source_kind(boot_id, _current) when is_binary(boot_id) and boot_id != "", do: :retained
  defp source_kind(_boot_id, _current), do: :history

  defp source_kind_label(:live), do: "live boot"
  defp source_kind_label(:retained), do: "retained run"
  defp source_kind_label(:history), do: "retained history"

  defp source_title(%{boot_id: boot_id, observed_at: observed_at}) do
    [
      if(is_binary(boot_id), do: "boot #{boot_id}"),
      if(observed_at, do: "observed #{DateTime.to_iso8601(observed_at)}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp source_title(_source), do: ""

  defp age_label(nil), do: "observed at an unknown time"
  defp age_label(age_ms) when age_ms <= @source_fresh_ms, do: "observed just now"
  defp age_label(age_ms), do: "observed #{elapsed_seconds(div(age_ms, 1000))} ago"

  defp elapsed_seconds(seconds) when seconds < 60, do: "#{seconds}s"
  defp elapsed_seconds(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  defp elapsed_seconds(seconds) when seconds < 86_400, do: "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
  defp elapsed_seconds(seconds), do: "#{div(seconds, 86_400)}d #{div(rem(seconds, 86_400), 3_600)}h"

  defp short_boot(nil), do: nil
  defp short_boot(id) when is_binary(id) and byte_size(id) > 8, do: binary_part(id, 0, 8)
  defp short_boot(id), do: id

  defp parse_observed(nil), do: nil

  defp parse_observed(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, observed_at, _offset} -> observed_at
      _invalid -> nil
    end
  end

  defp parse_observed(_other), do: nil

  defp safe_boot_id do
    Aiur.RunTelemetry.boot_id()
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp pressure_time(ms) when is_integer(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
  defp pressure_time(_ms), do: "—"
  defp pressure_value(nil), do: "—"
  defp pressure_value(value), do: to_string(value)
  defp pressure_values(sample, keys), do: Enum.map_join(keys, " / ", &pressure_value(Map.get(sample, &1)))

  defp pressure_seconds(nil), do: "—"
  defp pressure_seconds(value), do: "#{value}s"

  # The load gate holds at `load > threshold * schedulers`, so render both the
  # raw load and the scaled threshold the operator compares it against.
  defp pressure_load(load, threshold) when is_number(load) and is_number(threshold),
    do: "#{format_load(load)} / #{format_load(threshold)}"

  defp pressure_load(load, nil) when is_number(load), do: format_load(load)
  defp pressure_load(_load, _threshold), do: "—"

  defp format_load(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_load(value), do: to_string(value)

  # The live route defaults to the daemon-owned aggregate. The configurable
  # source exists only to keep the route's protected-query contract testable
  # without mutating the process-global ledger projection.
  defp usage_aggregate_source,
    do: Application.get_env(:aiur, :analytics_usage_aggregate_source, UsageAggregate)

  defp usage_aggregate_generation(usage_aggregate) do
    usage_aggregate.snapshot().generation
  rescue
    _error -> :unknown
  catch
    _kind, _reason -> :unknown
  end

  defp authorized_context(socket) do
    capability = Map.get(socket.assigns, :financial_data_capability, %{})

    case {Map.get(capability, :state), FinancialDataAccess.context(socket)} do
      {:authorized, %FinancialDataAccess.Context{} = context} -> {:ok, context}
      _other -> :locked
    end
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
