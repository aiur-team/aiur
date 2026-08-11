defmodule AiurWeb.BuildOrderLive do
  @moduledoc "Authenticated, read-only LiveView for Build Order catalog and selected-root routes."

  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias Aiur.BuildOrder.GraphProjection.Snapshot

  alias Aiur.TrackerIdentity

  alias AiurWeb.BuildOrder.{
    AnalyticsRuntime,
    ContextRuntime,
    DataSource,
    RouteState,
    Runtime,
    SourceRuntime,
    TicketContextSelection,
    UsageRuntime
  }

  alias AiurWeb.FinancialData
  alias AiurWeb.Presenter

  alias AiurWeb.OperatorControlCenter.{
    BuildOrderCatalog,
    BuildOrderSelected,
    BuildOrderTicketContext,
    DashboardShell,
    NavState,
    RouteRegistry
  }

  alias AiurWeb.OperatorControlCenter.Analytics.Charts

  @context_events TicketContextSelection.event_names()
  @ui_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket = NavState.assign_nav(socket)
    connected = connected?(socket)
    source = Application.get_env(:aiur, :build_order_data_source, DataSource)
    request_epoch = "build-order-live-#{System.unique_integer([:positive])}"
    route_state = RouteState.new(request_epoch)

    socket =
      socket
      |> assign(:route_state, route_state)
      |> SourceRuntime.initialize(source)
      |> ContextRuntime.initialize(request_epoch)
      |> UsageRuntime.initialize()
      |> AnalyticsRuntime.initialize()
      |> assign(:time_domain, nil)
      |> assign(:now, Runtime.display_now())
      |> assign(:tracker_kind, Runtime.tracker_kind())
      |> assign(:agent_kind, Runtime.agent_kind())
      |> assign(:current_route, RouteRegistry.current_route(Map.get(socket.assigns, :live_action)))
      |> assign(:analytics, Presenter.analytics_navigation())

    socket = if connected, do: socket |> SourceRuntime.connect() |> UsageRuntime.connect(), else: socket
    if connected, do: schedule_ui_tick()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    raw_identifier =
      case socket.assigns.live_action do
        :build_order -> Map.get(params, "root_number")
        :build_orders -> nil
      end

    {route_state, effects} = RouteState.navigate(socket.assigns.route_state, raw_identifier)

    socket =
      socket
      |> assign(:route_state, route_state)
      |> assign(:current_route, RouteRegistry.current_route(socket.assigns.live_action))
      |> SourceRuntime.apply_effects(effects)
      |> SourceRuntime.assign_model()
      |> UsageRuntime.sync_scope()
      |> AnalyticsRuntime.sync_scope()
      |> assign(:time_domain, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_info({kind, %Snapshot{} = snapshot}, socket)
      when kind in [:graph_projection_generation, :graph_projection_health] do
    {:noreply, socket |> SourceRuntime.accept_projection(snapshot) |> UsageRuntime.sync_scope() |> AnalyticsRuntime.sync_scope()}
  end

  def handle_info({:graph_projection_reset, generation}, socket) when is_integer(generation) do
    {:noreply, socket |> SourceRuntime.reset(generation) |> UsageRuntime.sync_scope() |> AnalyticsRuntime.sync_scope()}
  end

  def handle_info({FinancialData, :updated, _identity} = message, socket) do
    {:noreply, UsageRuntime.stash(socket, message)}
  end

  def handle_info(:flush_bo_usage, socket) do
    {:noreply, UsageRuntime.flush(socket)}
  end

  def handle_info(:build_order_ui_tick, socket) do
    schedule_ui_tick()
    {:noreply, socket |> assign(:now, Runtime.display_now()) |> AnalyticsRuntime.tick()}
  end

  def handle_info({:ticket_activity_changed, _payload}, socket),
    do: {:noreply, SourceRuntime.schedule_reload(socket)}

  def handle_info({:running_changed, _summaries}, socket),
    do: {:noreply, SourceRuntime.schedule_reload(socket)}

  def handle_info({:build_order_adhoc_updated, _snapshot}, socket),
    do: {:noreply, SourceRuntime.schedule_reload(socket)}

  def handle_info({event, _payload}, socket)
      when event in [:current_run_membership_changed, :current_run_membership_health_changed],
      do: {:noreply, SourceRuntime.refresh_live_state(socket)}

  def handle_info({:build_order_pack_status_changed, _health}, socket),
    do: {:noreply, SourceRuntime.refresh_live_state(socket)}

  def handle_info({event, %{identity: %TrackerIdentity{} = identity}}, socket)
      when event in [:ticket_detail_updated, :ticket_history_updated],
      do: {:noreply, ContextRuntime.refresh_for(socket, identity)}

  def handle_info({:ticket_history_evicted, %TrackerIdentity{} = identity, _generation}, socket),
    do: {:noreply, ContextRuntime.refresh_for(socket, identity)}

  def handle_info({event, _epoch}, socket)
      when event in [:ticket_detail_cache_reset, :ticket_history_reset],
      do: {:noreply, ContextRuntime.refresh(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:build_order_sources, {:ok, {token, sources}}, socket) do
    {:noreply, SourceRuntime.complete_reload(socket, token, sources)}
  end

  def handle_async(:build_order_sources, {:exit, _reason}, socket) do
    {:noreply, SourceRuntime.failed_reload(socket)}
  end

  def handle_async({:build_order_context, token}, {:ok, {identity, result}}, socket) do
    {:noreply, ContextRuntime.complete(socket, token, identity, result)}
  end

  def handle_async({:build_order_context, token}, {:exit, _reason}, socket),
    do: {:noreply, ContextRuntime.failed(socket, token)}

  def handle_async({:build_order_analytics, key}, {:ok, result}, socket) do
    {:noreply, socket |> AnalyticsRuntime.complete(key, result) |> reconcile_time_domain()}
  end

  def handle_async({:build_order_analytics, key}, {:exit, _reason}, socket) do
    {:noreply, AnalyticsRuntime.failed(socket, key)}
  end

  @impl true
  def handle_event("toggle-nav", _params, socket), do: {:noreply, NavState.toggle(socket)}

  @impl true
  def handle_event("restore-nav", %{"collapsed" => collapsed}, socket),
    do: {:noreply, NavState.restore(socket, collapsed)}

  @impl true
  def handle_event("open-ticket-context", %{"member" => navigation_value}, socket) do
    {:noreply, ContextRuntime.open(socket, navigation_value)}
  end

  def handle_event(event, %{"member" => navigation_value}, socket)
      when event == @context_events.replace do
    {:noreply, ContextRuntime.replace(socket, navigation_value)}
  end

  def handle_event(event, _params, socket) when event == @context_events.back do
    {:noreply, ContextRuntime.back(socket)}
  end

  def handle_event(event, _params, socket) when event == @context_events.close do
    {:noreply, ContextRuntime.close(socket)}
  end

  def handle_event("usage-drill-down", %{"dimension" => dimension}, socket) do
    {:noreply, UsageRuntime.open_drill(socket, dimension)}
  end

  def handle_event("usage-drill-more", %{"dimension" => dimension, "cursor" => cursor}, socket) do
    {:noreply, UsageRuntime.page_drill(socket, dimension, cursor)}
  end

  def handle_event("usage-drill-close", _params, socket) do
    {:noreply, UsageRuntime.close_drill(socket)}
  end

  def handle_event("time-domain", params, %{assigns: %{bo_analytics_model: model}} = socket) when not is_nil(model) do
    domain = Charts.normalize_time_domain(model, {Map.get(params, "t0"), Map.get(params, "t1")})
    {:noreply, assign(socket, :time_domain, domain)}
  end

  def handle_event("time-domain", _params, socket), do: {:noreply, socket}

  def handle_event("reset-time-domain", _params, socket) do
    {:noreply, assign(socket, :time_domain, nil)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    SourceRuntime.terminate(socket)
    ContextRuntime.terminate(socket)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <DashboardShell.dashboard_shell
      route={@current_route}
      routes={RouteRegistry.routes(@analytics)}
      title={page_title(@current_route, @route_state)}
      back_path={back_path(@current_route, @route_state)}
      back_label="Back to all Build Orders"
      tracker_kind={@tracker_kind}
      agent_kind={@agent_kind}
      nav_collapsed={@nav_collapsed}
    >
      <section
        id="build-order-page"
        class="bo-page"
        aria-label="Build Order explorer"
        data-build-order-status={RouteState.status(@route_state)}
        data-build-order-root={RouteState.root_identifier(@route_state)}
        data-build-order-catalog-state={BuildOrderCatalog.catalog_state(RouteState.catalog_snapshot(@route_state))}
      >
        <BuildOrderCatalog.build_order_catalog
          :if={RouteState.route(@route_state) == :catalog}
          route_state={@route_state}
          now={@now}
        />
        <BuildOrderSelected.build_order_selected
          :if={RouteState.route(@route_state) == :selected}
          route_state={@route_state}
          model={@model}
          adhoc={@adhoc_overlay}
          now={@now}
          analytics_scope={@bo_analytics_scope}
          analytics_model={@bo_analytics_model}
          analytics_unavailable={@bo_analytics_unavailable}
          analytics_loading={@bo_analytics_loading?}
          time_domain={@time_domain}
          usage_scope={@bo_usage_scope}
          usage_view={@bo_usage_view}
          usage_announcement={@bo_usage_announcement}
          usage_drill_down={@bo_usage_drill}
          usage_drill_trigger={@bo_usage_drill_trigger}
        />
      </section>

      <BuildOrderTicketContext.build_order_ticket_context
        :if={@context_selection.status == :open}
        id="build-order-ticket-context"
        context={@context_view}
        selection={@context_selection}
      />
    </DashboardShell.dashboard_shell>
    """
  end

  defp schedule_ui_tick, do: Process.send_after(self(), :build_order_ui_tick, @ui_tick_ms)

  defp page_title(route, route_state) do
    case {RouteState.route(route_state), RouteState.root_identifier(route_state)} do
      {:selected, identifier} when is_binary(identifier) -> "#{route.label} ##{identifier}"
      _route -> route.label
    end
  end

  defp back_path(route, route_state), do: if(RouteState.route(route_state) == :selected, do: route.path)

  defp reconcile_time_domain(%{assigns: %{bo_analytics_model: nil}} = socket), do: assign(socket, :time_domain, nil)

  defp reconcile_time_domain(%{assigns: %{bo_analytics_model: model, time_domain: domain}} = socket),
    do: assign(socket, :time_domain, Charts.normalize_time_domain(model, domain))
end
