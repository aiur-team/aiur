defmodule AiurWeb.AnalyticsLive do
  @moduledoc """
  Authenticated, read-only LiveView for live run utilization. It derives every
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
        <div :if={@unavailable} class="an-empty">
          <p><b>No run telemetry to analyze yet.</b></p>
          <p>These charts are derived from the durable run-telemetry stream. Start a run with telemetry enabled and this view will populate on the next visit.</p>
        </div>

        <div :if={!@unavailable} class="an-controls">
          <div>
            <span class="an-scope">Scope: <b>{scope_label(@analytics_scope)}</b></span>
            <p class="an-scope-note">
              {scope_note(@analytics_scope)}
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

    socket = assign(socket, :provider_spend, provider_spend(socket))

    case Presenter.load(opts) do
      {:ok, model} ->
        domain = Charts.normalize_time_domain(model, socket.assigns.time_domain)

        socket
        |> assign(
          model: model,
          selected: MapSet.new(model.actors, & &1.key),
          unavailable: nil,
          now: now
        )
        |> assign_time_domain(domain)

      {:unavailable, reason} ->
        assign(socket,
          model: nil,
          chart_model: nil,
          time_domain: nil,
          selected: MapSet.new(),
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
  defp provider_spend(socket) do
    case {connected?(socket), authorized_context(socket)} do
      {true, {:ok, context}} -> load_provider_spend(context, socket.assigns.analytics_scope)
      {_connected, :locked} -> %{state: :locked}
      {false, {:ok, _context}} -> %{state: :loading}
    end
  rescue
    _error -> %{state: :unavailable}
  catch
    _kind, _reason -> %{state: :unavailable}
  end

  defp load_provider_spend(context, analytics_scope) do
    usage_aggregate = usage_aggregate_source()

    with {:ok, scope} <- ScopeResolver.usage_scope(analytics_scope),
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

  defp scope_label(%{kind: :build_order, root_number: root_number}), do: "Build Order ##{root_number}, this session"
  defp scope_label(:session), do: "this session"
  defp scope_label(:unavailable), do: "selected Build Order unavailable"

  defp scope_note(%{kind: :build_order}), do: "Only the selected Build Order's typed members in this session."
  defp scope_note(:session), do: "The current live run only. Add a Build Order selection to scope this page to its members."
  defp scope_note(:unavailable), do: "The selected Build Order could not provide a valid member graph."

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
