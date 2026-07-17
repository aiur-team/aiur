defmodule AiurWeb.DashboardLive do
  @moduledoc """
  Phoenix LiveView shell for the Aiur Executor Control Center.
  """

  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias Aiur.{AgentChat, CurrentRunMembership, DecisionPubSub, TicketActivity, TrackerIdentity}
  alias Aiur.BuildOrder.{TicketDetailCache, TicketHistoryProvider}
  alias Aiur.BuildOrder.TicketDetail.State, as: TicketDetailState
  alias Aiur.BuildOrder.TicketHistory.Snapshot, as: TicketHistorySnapshot
  alias AiurWeb.{Endpoint, ObservabilityPubSub}
  alias AiurWeb.BuildOrder.TicketContextPresenter

  alias AiurWeb.OperatorControlCenter.{
    AgentLogModal,
    DashboardShell,
    DecisionEvents,
    DecisionInbox,
    DecisionPath,
    History,
    Overview,
    PayloadLoader,
    RecentOutcomes,
    RouteRegistry,
    TicketContext,
    UnitsFilters,
    UnitsPresenter,
    UnitsTable,
    UnitsURL
  }

  @runtime_tick_ms 1_000
  @decision_filters [:all, :open, :blocking, :undelivered, :supervisor, :resolved, :superseded]
  @decision_events DecisionEvents.events()

  @impl true
  def mount(_params, _session, socket) do
    connected = connected?(socket)

    if connected do
      :ok = ObservabilityPubSub.subscribe()
      :ok = DecisionPubSub.subscribe()
      :ok = CurrentRunMembership.subscribe()
      :ok = TicketActivity.subscribe()
    end

    payload = PayloadLoader.load(if connected, do: :fresh, else: :cached)

    socket =
      socket
      |> assign(:payload, payload)
      |> assign(:now, DateTime.utc_now())
      |> assign(:agent_log_modal, nil)
      |> assign(:drafts, %{})
      |> assign(:chat_errors, %{})
      |> assign(:decision_actions, %{})
      |> assign(:payload_reload_scheduled?, false)
      |> assign(:writable, dashboard_writable?())
      |> assign(:decision_filter, :all)
      |> assign(:decision_page, empty_decision_page())
      |> assign(:decision_query, %{})
      |> assign(:units_selection, UnitsURL.default_selection())
      |> assign_units_view()
      |> assign(:ticket_context, nil)
      |> assign(:ticket_context_detail, nil)
      |> assign(:ticket_context_history, nil)
      |> assign(:ticket_context_identity, nil)
      |> assign(:ticket_context_row, nil)
      |> assign(:ticket_context_subscriptions, MapSet.new())
      |> assign(:selected_decision_id, nil)
      |> assign(:selected_decision, nil)
      |> assign(:selected_decision_status, :none)
      |> assign(:selected_decision_health, nil)
      |> assign(:current_route, RouteRegistry.current_route(Map.get(socket.assigns, :live_action)))
      |> PayloadLoader.mark_loaded()

    if connected, do: schedule_runtime_tick()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter = normalize_filter(params["filter"])

    {:noreply,
     socket
     |> assign(:decision_filter, filter)
     |> assign(:current_route, RouteRegistry.current_route(Map.get(socket.assigns, :live_action)))
     |> assign_units_selection(params)
     |> assign_decision_page(filter, params)
     |> assign_selected_decision(params["decision_id"])
     |> maybe_canonicalize_units_url(params)}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, PayloadLoader.schedule(socket)}
  end

  @impl true
  def handle_info({:decision_changed, _decision_id, _version}, socket) do
    {:noreply, PayloadLoader.schedule(socket)}
  end

  def handle_info(:decision_metrics_changed, socket) do
    {:noreply, PayloadLoader.schedule(socket)}
  end

  def handle_info({:current_run_membership_changed, _payload}, socket) do
    {:noreply, PayloadLoader.schedule(socket)}
  end

  def handle_info({:current_run_membership_health_changed, _payload}, socket) do
    {:noreply, PayloadLoader.schedule(socket)}
  end

  def handle_info({:ticket_activity_changed, _payload}, socket) do
    {:noreply, PayloadLoader.schedule(socket)}
  end

  def handle_info({:ticket_detail_updated, %TicketDetailState{} = detail}, socket) do
    {:noreply, maybe_update_ticket_context(socket, :detail, detail)}
  end

  def handle_info({:ticket_history_updated, %TicketHistorySnapshot{} = history}, socket) do
    {:noreply, maybe_update_ticket_context(socket, :history, history)}
  end

  def handle_info({:ticket_history_evicted, identity, _generation}, socket) do
    {:noreply, maybe_reset_ticket_context(socket, :history, identity)}
  end

  def handle_info({:ticket_detail_cache_reset, _epoch}, socket) do
    {:noreply, reset_selected_ticket_context(socket, :detail)}
  end

  def handle_info({:ticket_history_reset, _epoch}, socket) do
    {:noreply, reset_selected_ticket_context(socket, :history)}
  end

  @impl true
  def handle_info(:reload_payload, socket) do
    {:noreply, socket |> reload_payload(:cached) |> PayloadLoader.mark_loaded()}
  end

  @impl true
  def handle_event("filter-decisions", %{"filter" => filter}, socket) do
    filter = normalize_filter(filter)
    {:noreply, push_patch(socket, to: decision_path(socket.assigns.selected_decision_id, filter, %{}))}
  end

  def handle_event("filter-decisions", _params, socket), do: {:noreply, socket}

  def handle_event("search-commands", %{"search" => search}, socket) when is_binary(search) do
    query =
      case String.trim(search) do
        "" -> %{}
        search -> %{search: String.slice(search, 0, 200)}
      end

    {:noreply, push_patch(socket, to: DecisionPath.inbox(:all, query))}
  end

  def handle_event("search-commands", _params, socket), do: {:noreply, socket}

  def handle_event("toggle-fleet-filter", _params, socket), do: {:noreply, socket}

  def handle_event("select-units-scope", %{"scope" => scope}, socket) do
    selection = UnitsPresenter.select_scope(socket.assigns.units_selection, scope)
    {:noreply, push_patch(socket, to: units_path(selection))}
  end

  def handle_event("select-units-scope", _params, socket), do: {:noreply, socket}

  def handle_event("toggle-units-condition", %{"condition" => condition}, socket) do
    selection = UnitsPresenter.toggle_condition(socket.assigns.units_selection, condition)
    {:noreply, push_patch(socket, to: units_path(selection))}
  end

  def handle_event("toggle-units-condition", _params, socket), do: {:noreply, socket}

  def handle_event("reset-units-filters", _params, socket) do
    {:noreply, push_patch(socket, to: units_path(UnitsURL.zero_result_reset()))}
  end

  def handle_event("inspect-unit", %{"unit" => token}, socket) when is_binary(token) do
    catalog = Map.get(socket.assigns.payload, :units, %{})

    case UnitsPresenter.lookup(catalog, token) do
      {:ok, row} -> {:noreply, open_ticket_context(socket, row)}
      {:error, :not_found} -> {:noreply, socket}
    end
  end

  def handle_event("inspect-unit", _params, socket), do: {:noreply, socket}

  def handle_event("close-ticket-context", _params, socket) do
    {:noreply,
     socket
     |> assign(:ticket_context, nil)
     |> assign(:ticket_context_detail, nil)
     |> assign(:ticket_context_history, nil)
     |> assign(:ticket_context_identity, nil)
     |> assign(:ticket_context_row, nil)}
  end

  def handle_event(event, params, socket) when event in @decision_events do
    handle_writable_event(socket, fn ->
      {:noreply, DecisionEvents.handle(event, params, socket, &reload_after_action/1)}
    end)
  end

  def handle_event("show-agent-log", %{"issue" => issue_identifier}, socket) do
    entry = AgentLogModal.find_running_entry(socket.assigns.payload, issue_identifier)
    {:noreply, assign(socket, :agent_log_modal, AgentLogModal.build(entry))}
  end

  def handle_event("show-agent-log", _params, socket), do: {:noreply, socket}

  def handle_event("close-agent-log", _params, socket) do
    {:noreply, assign(socket, :agent_log_modal, nil)}
  end

  def handle_event(
        "composer-change",
        %{"message" => message},
        %{assigns: %{writable: true, agent_log_modal: modal}} = socket
      )
      when is_map(modal) do
    handle_writable_event(socket, fn ->
      identifier = modal.issue_identifier

      {:noreply,
       socket
       |> assign(:drafts, Map.put(socket.assigns.drafts, identifier, message))
       |> assign(:chat_errors, Map.delete(socket.assigns.chat_errors, identifier))}
    end)
  end

  def handle_event("composer-change", _params, socket), do: {:noreply, socket}

  def handle_event(
        "send-operator-message",
        %{"message" => message},
        %{assigns: %{writable: true, agent_log_modal: modal}} = socket
      )
      when is_map(modal) do
    handle_writable_event(socket, fn ->
      {:noreply, send_operator_message(socket, modal.issue_identifier, String.trim(message))}
    end)
  end

  def handle_event("send-operator-message", _params, socket), do: {:noreply, socket}

  def handle_event(
        "pause-agent",
        _params,
        %{assigns: %{writable: true, agent_log_modal: modal}} = socket
      )
      when is_map(modal) do
    handle_writable_event(socket, fn ->
      identifier = modal.issue_identifier

      case AgentChat.pause(identifier) do
        {:ok, _request_id} ->
          {:noreply, assign(socket, :chat_errors, Map.delete(socket.assigns.chat_errors, identifier))}

        {:error, reason} ->
          {:noreply, put_chat_error(socket, identifier, reason)}
      end
    end)
  end

  def handle_event("pause-agent", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> Map.put_new(:selected_decision_health, nil)
      |> Map.put_new(:retained_counts, Map.get(assigns.payload, :retained_counts, unavailable_retained_counts()))
      |> Map.put_new(:decision_page, fallback_decision_page(assigns.payload))
      |> Map.put_new(:decision_query, %{})
      |> Map.put_new(:ticket_context, nil)
      |> Map.put_new(:units_selection, UnitsURL.default_selection())
      |> Map.put_new(
        :units_view,
        UnitsPresenter.project(Map.get(assigns.payload, :units, %{}), Map.get(assigns, :units_selection, UnitsURL.default_selection()))
      )
      |> Map.put_new(:current_route, RouteRegistry.current_route(Map.get(assigns, :live_action)))

    assigns = Map.put(assigns, :units_announcement, units_announcement(assigns.units_view))

    ~H"""
    <DashboardShell.dashboard_shell
      route={@current_route}
      routes={RouteRegistry.routes(@payload.analytics)}
      now={@now}
      tracker_kind={tracker_kind()}
      agent_kind={agent_kind()}
    >
      <Overview.readonly_banner writable={@writable} />
      <Overview.decisions_banner decisions={@payload.decisions} retained_counts={@retained_counts} />
      <Overview.error error={@payload.fleet[:error]} />

      <div :if={@live_action in [:decisions, :decision]} class="control-panel">
        <div :if={not is_nil(@selected_decision) and partial_detail?(@selected_decision_health)} class="readonly-banner" role="status" aria-live="polite">
          <span aria-hidden="true">◉</span>
          <span><b>Partial retained Command data.</b> This detail was recovered from the validated audit prefix.</span>
        </div>
        <div :if={@live_action == :decision and is_nil(@selected_decision)} class="error-card" role="alert">
          <h2>{selected_decision_error_title(@selected_decision_status)}</h2>
          <p>{selected_decision_error_message(@selected_decision_status, @selected_decision_id)}</p>
        </div>
        <DecisionInbox.decision_inbox
          decisions={@decision_page.decisions}
          selected_decision={@selected_decision}
          selected_decision_id={@selected_decision_id}
          filter={@decision_filter}
          now={@now}
          history={@payload.history}
          action_states={@decision_actions}
          writable={@writable}
          provider_health={page_provider_health(@decision_page)}
          retained_counts={@retained_counts}
          page={@decision_page}
          query={@decision_query}
        />
        <History.history entries={@payload.history} provider_health={@payload.provider_health.history} />
      </div>

      <div :if={@live_action not in [:decisions, :decision]} class="control-panel">
        <section class="section-card units-card" aria-labelledby="units-title">
          <header class="section-header units-header">
            <div>
              <p class="section-eyebrow">Current-run catalog</p>
              <h2 id="units-title" tabindex="-1">Units</h2>
              <p>
                {@units_view[:total_count] || 0} observed · {@units_view[:counts][:scope] || 0} in selected scope
              </p>
            </div>
          </header>

          <p id="units-status" class="sr-only" role="status" aria-live="polite" aria-atomic="true">
            {@units_announcement}
          </p>

          <UnitsFilters.units_filters selection={@units_selection} counts={@units_view[:counts] || %{}} />
          <UnitsTable.units_table view={@units_view} now={@now} />
        </section>
      </div>

      <section :if={@live_action == :index} class="section-card recent-card" aria-labelledby="recent-title">
        <header class="section-header">
          <div>
            <p class="section-eyebrow">Durable outcomes</p>
            <h2 id="recent-title">Recent</h2>
            <p>Repository merges and recorded Command actions from durable projections.</p>
          </div>
        </header>
        <RecentOutcomes.recent_outcomes
          outcomes={@payload.recent_outcomes}
          provider_health={@payload.provider_health.recent_outcomes}
          reconciliation={@payload.recent_outcomes_reconciliation}
          analytics={@payload.analytics}
        />
        <History.history entries={@payload.history} provider_health={@payload.provider_health.history} />
      </section>

      <AgentLogModal.agent_log_modal
        modal={@agent_log_modal}
        writable={@writable}
        drafts={@drafts}
        errors={@chat_errors}
      />
      <TicketContext.ticket_context
        :if={@ticket_context}
        id="units-ticket-context"
        context={@ticket_context}
        close_event="close-ticket-context"
        fallback_focus_id="units-title"
      />
    </DashboardShell.dashboard_shell>
    """
  end

  defp reload_payload(socket, mode) do
    payload = PayloadLoader.load(mode)

    socket
    |> assign(:payload, payload)
    |> assign(:now, DateTime.utc_now())
    |> assign(:agent_log_modal, AgentLogModal.refresh(socket.assigns.agent_log_modal, payload))
    |> assign_units_view()
    |> refresh_ticket_context_row()
    |> reload_decision_page()
    |> assign_selected_decision(socket.assigns.selected_decision_id)
  end

  defp reload_after_action(socket) do
    socket
    |> reload_payload(:fresh)
    |> PayloadLoader.mark_loaded()
  end

  defp assign_selected_decision(socket, decision_id) do
    {selected, status, health} =
      case PayloadLoader.detail(decision_id) do
        :none -> {nil, :none, nil}
        {:ok, %{decision: decision, health: health}} -> {decision, :available, health}
        {:error, :not_found} -> {nil, :not_found, nil}
        {:error, {:indeterminate, health}} -> {nil, :indeterminate, health}
        {:error, {:invalid_decision_id, _reason}} -> {nil, :not_found, nil}
        {:error, _reason} -> {nil, :unavailable, nil}
      end

    socket
    |> clear_stale_action_state(selected)
    |> assign(:selected_decision_id, decision_id)
    |> assign(:selected_decision, selected)
    |> assign(:selected_decision_status, status)
    |> assign(:selected_decision_health, health)
  end

  defp selected_decision_error_title(:unavailable), do: "Command unavailable"
  defp selected_decision_error_title(:indeterminate), do: "Command presence unknown"
  defp selected_decision_error_title(_status), do: "Command not found"

  defp selected_decision_error_message(:unavailable, decision_id),
    do: "Retained Command data is currently unavailable for #{decision_id}. The overview remains available."

  defp selected_decision_error_message(:indeterminate, decision_id),
    do: "#{decision_id} may exist beyond the validated audit prefix, so it cannot be reported as absent. The overview remains available."

  defp selected_decision_error_message(_status, decision_id),
    do: "No retained Command matches #{decision_id}."

  defp partial_detail?(%{status: :partial}), do: true
  defp partial_detail?(_health), do: false

  defp clear_stale_action_state(socket, nil), do: socket

  defp clear_stale_action_state(socket, %{decision_id: decision_id} = selected) do
    identity = decision_identity(selected)

    case Map.get(socket.assigns.decision_actions, decision_id) do
      nil ->
        socket

      %{decision_identity: ^identity} ->
        socket

      _state ->
        assign(socket, :decision_actions, Map.delete(socket.assigns.decision_actions, decision_id))
    end
  end

  defp decision_identity(decision) do
    {Map.get(decision, :version), Map.get(decision, :active_action_id)}
  end

  defp unavailable_retained_counts do
    %{
      open: nil,
      blocking: nil,
      total: nil,
      health: %{status: :unavailable, label: "Retained Command counts unavailable"}
    }
  end

  defp normalize_filter(filter) when is_atom(filter) and filter in @decision_filters, do: filter

  defp normalize_filter(filter) when is_binary(filter) do
    Enum.find(@decision_filters, :all, &(Atom.to_string(&1) == filter))
  end

  defp normalize_filter(_filter), do: :all
  defp dashboard_writable?, do: Endpoint.config(:dashboard_writable) == true

  defp decision_path(nil, filter, query), do: DecisionPath.inbox(filter, query)
  defp decision_path(decision_id, filter, query), do: DecisionPath.detail(decision_id, filter, query)

  defp units_path(selection), do: "/?" <> UnitsURL.encode(selection)

  defp units_announcement(view) do
    visible = view |> Map.get(:rows, []) |> length()
    total = Map.get(view, :total_count, 0)

    case Map.get(view, :status, :loading) do
      :loading -> "Loading Units."
      :unavailable -> "Units catalog unavailable."
      :empty -> "No units have been observed in this run."
      :stale -> "Showing #{visible} of #{total} Units from stale catalog data."
      _status -> "Showing #{visible} of #{total} Units."
    end
  end

  defp assign_units_selection(socket, params) do
    selection = UnitsURL.decode(params)

    socket
    |> assign(:units_selection, selection)
    |> assign_units_view()
  end

  defp maybe_canonicalize_units_url(socket, params) do
    selection = socket.assigns.units_selection

    if socket.assigns.live_action == :index and map_size(params) > 0 and
         params != Map.new(UnitsURL.params(selection)) do
      push_patch(socket, to: units_path(selection), replace: true)
    else
      socket
    end
  end

  defp assign_units_view(socket) do
    catalog = socket.assigns.payload |> Map.get(:units, %{})
    assign(socket, :units_view, UnitsPresenter.project(catalog, socket.assigns.units_selection))
  end

  defp open_ticket_context(socket, %{identity: %TrackerIdentity{} = identity} = row) do
    socket = subscribe_ticket_context(socket, identity)
    detail = request_context(:ticket_detail_request_fun, &TicketDetailCache.request/1, identity)
    history = request_context(:ticket_history_request_fun, &TicketHistoryProvider.request/1, identity)

    socket
    |> assign(:ticket_context_identity, identity)
    |> assign(:ticket_context_row, row)
    |> assign_ticket_context(detail, history)
  end

  defp open_ticket_context(socket, _row), do: socket

  defp subscribe_ticket_context(socket, identity) do
    key = TrackerIdentity.github_key(identity)
    subscriptions = socket.assigns.ticket_context_subscriptions

    if is_nil(key) do
      socket
    else
      subscriptions =
        subscriptions
        |> ensure_ticket_context_subscription(
          {key, :detail},
          :ticket_detail_subscribe_fun,
          &TicketDetailCache.subscribe/1,
          identity
        )
        |> ensure_ticket_context_subscription(
          {key, :history},
          :ticket_history_subscribe_fun,
          &TicketHistoryProvider.subscribe/1,
          identity
        )

      assign(socket, :ticket_context_subscriptions, subscriptions)
    end
  end

  defp ensure_ticket_context_subscription(subscriptions, marker, config_key, default, identity) do
    cond do
      MapSet.member?(subscriptions, marker) -> subscriptions
      call_context(config_key, default, identity) == :ok -> MapSet.put(subscriptions, marker)
      true -> subscriptions
    end
  end

  defp request_context(config_key, default, identity) do
    case call_context(config_key, default, identity) do
      {:ok, value} -> value
      _error -> nil
    end
  end

  defp call_context(config_key, default, identity) do
    fun = Endpoint.config(config_key) || default
    fun.(identity)
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
    _kind, _reason -> {:error, :unavailable}
  end

  defp assign_ticket_context(socket, detail, history) do
    identity = socket.assigns.ticket_context_identity
    row = socket.assigns.ticket_context_row
    detail = valid_detail(detail, identity)
    history = valid_history(history, identity)
    context = TicketContextPresenter.present(detail, history, ticket_context_capabilities(row))

    socket
    |> assign(:ticket_context_detail, detail)
    |> assign(:ticket_context_history, history)
    |> assign(:ticket_context, context)
  end

  defp valid_detail(%TicketDetailState{} = detail, identity) do
    if same_identity?(detail.identity, identity), do: detail, else: unavailable_detail(identity)
  end

  defp valid_detail(_detail, identity), do: unavailable_detail(identity)

  defp valid_history(%TicketHistorySnapshot{} = history, identity) do
    if same_identity?(history.identity, identity), do: history, else: unavailable_history(identity)
  end

  defp valid_history(_history, identity), do: unavailable_history(identity)

  defp unavailable_detail(identity) do
    %TicketDetailState{identity: identity, generation: :unknown, health: :unavailable}
  end

  defp unavailable_history(identity) do
    %TicketHistorySnapshot{
      identity: identity,
      generation: :unknown,
      health: :unavailable,
      status_label: "Ticket history unavailable",
      progress: %{status: :unknown},
      latest_evidence: %{status: :unknown},
      entries: [],
      truncated?: false,
      freshness: :unknown,
      source_health: %{activity: :unavailable, history: :unavailable}
    }
  end

  defp ticket_context_capabilities(%{identity: %TrackerIdentity{identifier: identifier}, url: url}) do
    [
      %{
        kind: :github,
        variant: :issue,
        available?: is_binary(url),
        href: url,
        reason: :not_available
      },
      %{kind: :chat, available?: false, reason: :not_available},
      %{
        kind: :commands,
        available?: is_binary(identifier),
        href: DecisionPath.inbox(:all, %{search: identifier}),
        reason: :not_available
      }
    ]
  end

  defp ticket_context_capabilities(_row), do: []

  defp maybe_update_ticket_context(socket, kind, snapshot) do
    if same_identity?(Map.get(snapshot, :identity), socket.assigns.ticket_context_identity) do
      case kind do
        :detail -> assign_ticket_context(socket, snapshot, socket.assigns.ticket_context_history)
        :history -> assign_ticket_context(socket, socket.assigns.ticket_context_detail, snapshot)
      end
    else
      socket
    end
  end

  defp maybe_reset_ticket_context(socket, kind, identity) do
    if same_identity?(identity, socket.assigns.ticket_context_identity) do
      reset_selected_ticket_context(socket, kind)
    else
      socket
    end
  end

  defp reset_selected_ticket_context(%{assigns: %{ticket_context_identity: nil}} = socket, _kind), do: socket

  defp reset_selected_ticket_context(socket, :detail) do
    assign_ticket_context(socket, nil, socket.assigns.ticket_context_history)
  end

  defp reset_selected_ticket_context(socket, :history) do
    assign_ticket_context(socket, socket.assigns.ticket_context_detail, nil)
  end

  defp refresh_ticket_context_row(%{assigns: %{ticket_context_identity: nil}} = socket), do: socket

  defp refresh_ticket_context_row(socket) do
    rows = get_in(socket.assigns.payload, [:units, :snapshot, :rows]) || []

    case Enum.find(rows, &same_identity?(Map.get(&1, :identity), socket.assigns.ticket_context_identity)) do
      nil ->
        socket

      row ->
        socket
        |> assign(:ticket_context_row, row)
        |> assign_ticket_context(socket.assigns.ticket_context_detail, socket.assigns.ticket_context_history)
    end
  end

  defp same_identity?(%TrackerIdentity{} = left, %TrackerIdentity{} = right) do
    key = TrackerIdentity.github_key(left)
    not is_nil(key) and key == TrackerIdentity.github_key(right)
  end

  defp same_identity?(_left, _right), do: false

  defp assign_decision_page(socket, filter, params) do
    case Map.get(socket.assigns, :live_action) do
      :decisions ->
        do_assign_decision_page(socket, filter, params)

      :decision ->
        socket
        |> assign(:decision_page, fallback_decision_page(socket.assigns.payload))
        |> assign(:decision_query, decision_query(filter, params))

      _action ->
        socket
    end
  end

  defp do_assign_decision_page(socket, filter, params) do
    query = decision_query(filter, params)

    page =
      case PayloadLoader.decisions(provider_query(filter, query)) do
        {:ok, page} -> page
        {:error, reason} -> unavailable_decision_page(reason)
      end

    socket
    |> assign(:decision_page, page)
    |> assign(:decision_query, query)
  end

  defp reload_decision_page(socket) do
    case Map.get(socket.assigns, :live_action) do
      :decisions -> do_reload_decision_page(socket)
      :decision -> assign(socket, :decision_page, fallback_decision_page(socket.assigns.payload))
      _action -> socket
    end
  end

  defp do_reload_decision_page(socket) do
    filter = Map.get(socket.assigns, :decision_filter, :all)
    query = Map.get(socket.assigns, :decision_query, %{})

    page =
      case PayloadLoader.decisions(provider_query(filter, query)) do
        {:ok, page} -> page
        {:error, reason} -> unavailable_decision_page(reason)
      end

    assign(socket, :decision_page, page)
  end

  defp decision_query(:all, params) do
    %{}
    |> maybe_put_query(:search, params["search"])
    |> maybe_put_query(:cursor, params["cursor"])
  end

  defp decision_query(_filter, params), do: %{} |> maybe_put_query(:cursor, params["cursor"])

  defp provider_query(filter, query) do
    query
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.put("limit", 25)
    |> put_filter_query(filter)
  end

  defp put_filter_query(query, :open), do: Map.put(query, "lifecycle", "open")

  defp put_filter_query(query, :blocking), do: query |> Map.put("lifecycle", "open") |> Map.put("blocking", true)
  defp put_filter_query(query, :resolved), do: Map.put(query, "lifecycle", "resolved")
  defp put_filter_query(query, _filter), do: query

  defp maybe_put_query(query, key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> query
      value -> Map.put(query, key, value)
    end
  end

  defp maybe_put_query(query, _key, _value), do: query

  defp empty_decision_page do
    %{
      decisions: [],
      health: %{status: :available, partial?: false},
      pagination: %{total: 0, next_cursor: nil, label: "Retained Command page"}
    }
  end

  defp fallback_decision_page(payload) do
    decisions = Map.get(payload, :decisions, [])

    %{
      decisions: decisions,
      health: %{status: :available, partial?: false},
      pagination: %{
        total: length(decisions),
        next_cursor: nil,
        label: "Priority Command overview"
      }
    }
  end

  defp unavailable_decision_page(reason) do
    %{
      decisions: [],
      health: %{status: :unavailable, partial?: true, reason: reason},
      pagination: %{total: nil, next_cursor: nil, label: "Retained Command page unavailable"}
    }
  end

  defp page_provider_health(%{health: %{status: status}}) when status in [:available, :partial], do: :ok
  defp page_provider_health(_page), do: :unavailable

  defp handle_writable_event(socket, fun) when is_function(fun, 0) do
    if dashboard_writable?() do
      fun.()
    else
      {:noreply, assign(socket, :writable, false)}
    end
  end

  defp tracker_kind, do: to_string(Aiur.Config.tracker_kind())
  defp agent_kind, do: to_string(Aiur.Config.agent_kind())

  defp schedule_runtime_tick, do: Process.send_after(self(), :runtime_tick, @runtime_tick_ms)

  defp clear_chat_state(socket, identifier) do
    socket
    |> assign(:drafts, Map.delete(socket.assigns.drafts, identifier))
    |> assign(:chat_errors, Map.delete(socket.assigns.chat_errors, identifier))
  end

  defp put_chat_error(socket, identifier, reason) do
    assign(socket, :chat_errors, Map.put(socket.assigns.chat_errors, identifier, AgentLogModal.format_error(reason)))
  end

  defp send_operator_message(socket, _identifier, ""), do: socket

  defp send_operator_message(socket, identifier, text) do
    case AgentChat.send(identifier, text) do
      {:ok, _request_id} -> clear_chat_state(socket, identifier)
      {:error, reason} -> put_chat_error(socket, identifier, reason)
    end
  end
end
