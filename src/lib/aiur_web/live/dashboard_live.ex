defmodule AiurWeb.DashboardLive do
  @moduledoc """
  Phoenix LiveView shell for the Aiur Executor Control Center.
  """

  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias Aiur.AgentChat
  alias Aiur.AgentPubSub
  alias Aiur.BuildOrder.TicketDetail.State, as: TicketDetailState
  alias Aiur.BuildOrder.TicketDetailCache
  alias Aiur.BuildOrder.TicketHistory.Snapshot, as: TicketHistorySnapshot
  alias Aiur.BuildOrder.TicketHistoryProvider
  alias Aiur.CurrentRunMembership
  alias Aiur.CurrentRunSummary
  alias Aiur.DecisionPubSub
  alias Aiur.LiveConversation
  alias Aiur.Orchestrator.Slots
  alias Aiur.TicketActivity
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.TicketContextPresenter
  alias AiurWeb.Endpoint
  alias AiurWeb.ObservabilityPubSub

  alias AiurWeb.OperatorControlCenter.{
    AgentLogModal,
    CapacityControl,
    CapacityPresenter,
    ConversationDrawer,
    DashboardShell,
    DecisionEvents,
    DecisionInbox,
    DecisionPath,
    History,
    Overview,
    PayloadLoader,
    RecentOutcomes,
    RouteRegistry,
    RunSummary,
    RunSummaryPresenter,
    TicketContext,
    UnitsControlPolicy,
    UnitsFilters,
    UnitsPresenter,
    UnitsTable,
    UnitsURL
  }

  alias AiurWeb.OperatorControlCenter.ConversationDrawer.Presenter, as: ConversationPresenter

  @runtime_tick_ms 1_000
  @run_summary_flush_ms 250
  @decision_filters [:all, :open, :blocking, :undelivered, :supervisor, :resolved, :superseded]
  @decision_events DecisionEvents.events()

  @impl true
  def mount(_params, _session, socket) do
    connected = connected?(socket)

    if connected do
      :ok = ObservabilityPubSub.subscribe()
      :ok = DecisionPubSub.subscribe()
      :ok = CurrentRunMembership.subscribe()
      :ok = CurrentRunSummary.subscribe()
      :ok = TicketActivity.subscribe()
      :ok = subscribe_ticket_context_resets()
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
      |> assign(:payload_reload_mode, :cached)
      |> assign(:writable, dashboard_writable?())
      |> assign(:decision_filter, :all)
      |> assign(:decision_page, empty_decision_page())
      |> assign(:decision_query, %{})
      |> assign(:units_selection, UnitsURL.default_selection())
      |> assign(:unit_controls, %{})
      |> assign(:unit_control_subscriptions, MapSet.new())
      |> assign_units_view()
      |> sync_unit_control_subscriptions(connected)
      |> assign(:capacity_input, "")
      |> assign(:capacity_feedback, nil)
      |> assign_initial_run_summary(connected)
      |> assign(:ticket_context, nil)
      |> assign(:ticket_context_detail, nil)
      |> assign(:ticket_context_history, nil)
      |> assign(:ticket_context_identity, nil)
      |> assign(:ticket_context_row, nil)
      |> assign(:ticket_context_subscriptions, MapSet.new())
      |> assign(:conversation_drawer, nil)
      |> assign(:conversation_handle, nil)
      |> assign(:conversation_identity, nil)
      |> assign(:conversation_row, nil)
      |> assign(:conversation_origin_id, nil)
      |> assign(:conversation_lifecycle, :active)
      |> assign(:conversation_snapshot, nil)
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

  def handle_info({:observability_updated, event_id}, socket) do
    {:noreply, PayloadLoader.schedule(socket, {:event, {:observability, event_id}})}
  end

  @impl true
  def handle_info({:decision_changed, decision_id, version}, socket) do
    {:noreply, PayloadLoader.schedule(socket, {:event, {:decision, decision_id, version}})}
  end

  def handle_info(:decision_metrics_changed, socket) do
    {:noreply, PayloadLoader.schedule(socket)}
  end

  def handle_info({:current_run_membership_changed, payload}, socket) do
    {:noreply, PayloadLoader.schedule(socket, {:event, {:membership, Map.get(payload, :generation)}})}
  end

  def handle_info({:current_run_summary_changed, snapshot}, socket) do
    {:noreply, stash_run_summary(socket, snapshot)}
  end

  def handle_info(:flush_run_summary, socket) do
    {:noreply, flush_run_summary(socket)}
  end

  def handle_info({:current_run_membership_health_changed, payload}, socket) do
    {:noreply, PayloadLoader.schedule(socket, {:event, {:membership_health, Map.get(payload, :generation)}})}
  end

  def handle_info({:ticket_activity_changed, payload}, socket) do
    {:noreply, PayloadLoader.schedule(socket, {:event, {:activity, Map.get(payload, :generation)}})}
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

  def handle_info({:live_conversation_changed, snapshot}, socket) do
    {:noreply, maybe_update_conversation(socket, snapshot)}
  end

  def handle_info({:live_conversation_restarted, _epoch, _now}, socket) do
    {:noreply, supersede_conversation(socket)}
  end

  @impl true
  def handle_info(:reload_payload, socket) do
    mode = Map.get(socket.assigns, :payload_reload_mode, :cached)
    {:noreply, socket |> reload_payload(mode) |> PayloadLoader.mark_loaded()}
  end

  def handle_info({:control_lifecycle, payload}, socket) when is_map(payload) do
    {:noreply, apply_control_lifecycle(socket, payload)}
  end

  # A unit's agent topic also carries transcript, alert, turn, and aiur-turn
  # traffic that this view subscribes for the control lifecycle but does not
  # otherwise consume. Ignore that noise — and any future message added to a
  # topic this view does not own — rather than crashing every open dashboard.
  def handle_info(_message, socket), do: {:noreply, socket}

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

  def handle_event("request-unit-control", %{"unit" => token, "action" => action}, socket)
      when is_binary(token) and action in ["pause", "resume"] do
    handle_writable_event(socket, fn ->
      {:noreply, request_unit_control(socket, token, String.to_existing_atom(action))}
    end)
  end

  def handle_event("request-unit-control", _params, socket), do: {:noreply, socket}

  def handle_event("close-ticket-context", _params, socket) do
    {:noreply,
     socket
     |> unsubscribe_ticket_context()
     |> assign(:ticket_context, nil)
     |> assign(:ticket_context_detail, nil)
     |> assign(:ticket_context_history, nil)
     |> assign(:ticket_context_identity, nil)
     |> assign(:ticket_context_row, nil)}
  end

  def handle_event("read-conversation", %{"unit" => token}, socket) when is_binary(token) do
    catalog = Map.get(socket.assigns.payload, :units, %{})

    with {:ok, row} <- UnitsPresenter.lookup(catalog, token),
         handle when is_binary(handle) <- conversation_handle(row),
         {:ok, snapshot} <- resolve_conversation(handle) do
      {:noreply, open_conversation(socket, row, token, handle, snapshot)}
    else
      _not_available -> {:noreply, socket}
    end
  end

  def handle_event("read-conversation", _params, socket), do: {:noreply, socket}

  def handle_event("close-conversation", _params, socket) do
    {:noreply, close_conversation(socket)}
  end

  def handle_event(event, params, socket) when event in @decision_events do
    handle_writable_event(socket, fn ->
      {:noreply, DecisionEvents.handle(event, params, socket, &reload_after_action/1)}
    end)
  end

  def handle_event("show-agent-log", %{"unit" => token}, socket) when is_binary(token) do
    catalog = Map.get(socket.assigns.payload, :units, %{})

    with {:ok, row} <- UnitsPresenter.lookup(catalog, token),
         %{} = entry <- AgentLogModal.find_running_entry(socket.assigns.payload, row.identity) do
      {:noreply, assign(socket, :agent_log_modal, AgentLogModal.build(entry, socket.assigns.payload))}
    else
      _not_found -> {:noreply, socket}
    end
  end

  def handle_event("show-agent-log", %{"issue" => issue_identifier}, socket) when is_binary(issue_identifier) do
    entry = AgentLogModal.find_running_entry(socket.assigns.payload, issue_identifier)
    {:noreply, assign(socket, :agent_log_modal, AgentLogModal.build(entry, socket.assigns.payload))}
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
      key = agent_log_key(modal)

      {:noreply,
       socket
       |> assign(:drafts, Map.put(socket.assigns.drafts, key, message))
       |> assign(:chat_errors, Map.delete(socket.assigns.chat_errors, key))}
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
      if Map.get(modal, :writable_target?) == true do
        {:noreply,
         send_operator_message(
           socket,
           agent_log_target(modal),
           agent_log_key(modal),
           String.trim(message)
         )}
      else
        {:noreply, put_chat_error(socket, agent_log_key(modal), :ambiguous_identifier)}
      end
    end)
  end

  def handle_event("send-operator-message", _params, socket), do: {:noreply, socket}

  def handle_event(
        "pause-agent",
        _params,
        %{assigns: %{writable: true, agent_log_modal: modal}} = socket
      )
      when is_map(modal) do
    handle_writable_event(socket, fn -> pause_agent_action(socket, modal) end)
  end

  def handle_event("pause-agent", _params, socket), do: {:noreply, socket}

  def handle_event("capacity-input-change", %{"max" => value}, socket) when is_binary(value) do
    {:noreply, assign(socket, :capacity_input, value)}
  end

  def handle_event("capacity-input-change", _params, socket), do: {:noreply, socket}

  def handle_event("capacity-decrement", _params, socket) do
    handle_writable_event(socket, fn -> {:noreply, adjust_capacity(socket, -1)} end)
  end

  def handle_event("capacity-increment", _params, socket) do
    handle_writable_event(socket, fn -> {:noreply, adjust_capacity(socket, 1)} end)
  end

  def handle_event("capacity-set", %{"max" => value}, socket) when is_binary(value) do
    handle_writable_event(socket, fn -> {:noreply, set_capacity(socket, value)} end)
  end

  def handle_event("capacity-set", _params, socket), do: {:noreply, socket}

  defp pause_agent_action(socket, modal) do
    key = agent_log_key(modal)

    if Map.get(modal, :writable_target?) == true do
      modal
      |> agent_log_target()
      |> pause_agent()
      |> pause_agent_result(socket, key)
    else
      {:noreply, put_chat_error(socket, key, :ambiguous_identifier)}
    end
  end

  defp pause_agent_result({:ok, _request_id}, socket, key),
    do: {:noreply, assign(socket, :chat_errors, Map.delete(socket.assigns.chat_errors, key))}

  defp pause_agent_result({:error, reason}, socket, key),
    do: {:noreply, put_chat_error(socket, key, reason)}

  defp adjust_capacity(socket, delta) do
    prior = capacity_max(socket.assigns.payload)
    reconcile_capacity(socket, capacity_adjust(delta), prior)
  end

  defp set_capacity(socket, value) do
    case parse_capacity(value) do
      {:ok, next} ->
        prior = capacity_max(socket.assigns.payload)
        reconcile_capacity(socket, capacity_set(next), prior)

      :error ->
        assign(socket, :capacity_feedback, %{kind: :invalid})
    end
  end

  defp reconcile_capacity(socket, {:ok, %{} = status}, prior) do
    new_max = Map.get(status, :max)

    kind =
      cond do
        is_integer(prior) and new_max == prior -> :noop
        Map.get(status, :draining?) == true -> :draining
        true -> :applied
      end

    socket
    |> reload_after_action()
    |> assign(:capacity_feedback, %{kind: kind, max: new_max})
  end

  defp reconcile_capacity(socket, {:error, reason}, _prior) do
    assign(socket, :capacity_feedback, %{kind: capacity_error_kind(reason)})
  end

  defp capacity_error_kind(:timeout), do: :timeout
  defp capacity_error_kind(_reason), do: :unavailable

  defp parse_capacity(value) do
    case value |> to_string() |> String.trim() |> Integer.parse() do
      {next, ""} when next >= 1 -> {:ok, next}
      _other -> :error
    end
  end

  defp capacity_facts(payload), do: get_in(payload, [:fleet, :capacity])

  defp capacity_max(payload) do
    case capacity_facts(payload) do
      %{max: max} when is_integer(max) -> max
      _other -> nil
    end
  end

  defp capacity_adjust(delta) do
    case Endpoint.config(:capacity_adjust_fun) do
      fun when is_function(fun, 1) -> fun.(delta)
      _other -> Slots.adjust_max_concurrent_agents(capacity_orchestrator(), delta)
    end
  end

  defp capacity_set(next) do
    case Endpoint.config(:capacity_set_fun) do
      fun when is_function(fun, 1) -> fun.(next)
      _other -> Slots.set_max_concurrent_agents(capacity_orchestrator(), next)
    end
  end

  defp capacity_orchestrator, do: Endpoint.config(:orchestrator) || Aiur.Orchestrator

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> Map.put_new(:selected_decision_health, nil)
      |> Map.put_new(:retained_counts, Map.get(assigns.payload, :retained_counts, unavailable_retained_counts()))
      |> Map.put_new(:decision_page, fallback_decision_page(assigns.payload))
      |> Map.put_new(:decision_query, %{})
      |> Map.put_new(:ticket_context, nil)
      |> Map.put_new(:unit_controls, %{})
      |> Map.put_new(:conversation_drawer, nil)
      |> Map.put_new(:conversation_origin_id, nil)
      |> Map.put_new(:units_selection, UnitsURL.default_selection())
      |> Map.put_new(
        :units_view,
        UnitsPresenter.project(Map.get(assigns.payload, :units, %{}), Map.get(assigns, :units_selection, UnitsURL.default_selection()))
      )
      |> then(&Map.put_new(&1, :units_announcement, UnitsPresenter.announcement(&1.units_view)))
      |> Map.put_new(:capacity_view, CapacityPresenter.present(capacity_facts(assigns.payload)))
      |> Map.put_new(:capacity_input, "")
      |> Map.put_new(:capacity_feedback, nil)
      |> Map.put_new(:run_summary, RunSummaryPresenter.present(nil))
      |> Map.put_new(:run_summary_announcement, nil)
      |> Map.put_new(:current_route, RouteRegistry.current_route(Map.get(assigns, :live_action)))

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
        <CapacityControl.capacity_control
          capacity={@capacity_view}
          writable={@writable}
          input={@capacity_input}
          feedback={@capacity_feedback}
        />
        <RunSummary.run_summary view={@run_summary} announcement={@run_summary_announcement} />
        <section class="section-card units-card" aria-labelledby="units-title">
          <header class="section-header units-header">
            <div>
              <p class="section-eyebrow">Current-run catalog</p>
              <h2 id="units-title" tabindex="-1">Units</h2>
              <p>{units_count_summary(@units_view)}</p>
            </div>
          </header>

          <p id="units-status" class="sr-only" role="status" aria-live="polite" aria-atomic="true">
            {@units_announcement}
          </p>

          <UnitsFilters.units_filters
            selection={@units_selection}
            counts={@units_view[:counts] || %{}}
            count_status={@units_view[:count_status] || :unavailable}
          />
          <UnitsTable.units_table view={@units_view} now={@now} controls={@unit_controls} writable={@writable} />
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
      <ConversationDrawer.conversation_drawer
        :if={@conversation_drawer}
        id="units-conversation-drawer"
        view={@conversation_drawer}
        close_event="close-conversation"
        fallback_focus_id="units-title"
        origin_id={@conversation_origin_id}
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
    |> sync_unit_control_subscriptions(connected?(socket))
    |> reconcile_unit_controls()
    |> refresh_ticket_context_row()
    |> refresh_conversation_row()
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

  defp units_count_summary(%{count_status: :unavailable}),
    do: "Observed and selected-scope counts unavailable"

  defp units_count_summary(%{count_status: :partial, total_count: total, counts: %{scope: scope}}),
    do: "At least #{total} observed · at least #{scope} in selected scope"

  defp units_count_summary(%{total_count: total, counts: %{scope: scope}})
       when is_integer(total) and is_integer(scope),
       do: "#{total} observed · #{scope} in selected scope"

  defp units_count_summary(_view), do: "Observed and selected-scope counts unavailable"

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
    view = UnitsPresenter.project(catalog, socket.assigns.units_selection)

    socket
    |> assign(:units_view, view)
    |> assign(:units_announcement, UnitsPresenter.announcement(view))
  end

  # Read the current DASH-014 snapshot on mount/reconnect. On the dead first
  # render, or when the projection process is unreachable, fall back to the
  # loading view rather than crashing the LiveView.
  defp assign_initial_run_summary(socket, connected) do
    snapshot = if connected, do: read_run_summary_snapshot(), else: nil

    socket
    |> assign(:run_summary_source, nil)
    |> assign(:run_summary_pending, nil)
    |> assign(:run_summary_flush_scheduled?, false)
    |> apply_run_summary(snapshot)
  end

  defp read_run_summary_snapshot do
    CurrentRunSummary.snapshot()
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  # Coalesce bursts of daemon updates: keep only the latest pending snapshot
  # and flush once per debounce window so high-frequency renders and
  # screen-reader announcements stay bounded.
  defp stash_run_summary(socket, snapshot) do
    socket = assign(socket, :run_summary_pending, snapshot)

    if socket.assigns.run_summary_flush_scheduled? do
      socket
    else
      schedule_run_summary_flush()
      assign(socket, :run_summary_flush_scheduled?, true)
    end
  end

  defp flush_run_summary(socket) do
    socket = assign(socket, :run_summary_flush_scheduled?, false)

    case socket.assigns.run_summary_pending do
      nil -> socket
      snapshot -> socket |> assign(:run_summary_pending, nil) |> apply_run_summary(snapshot)
    end
  end

  # Reconcile an incoming snapshot against the displayed source (last-known-good
  # retention lives in the presenter) and assign the presented view plus a
  # single bounded announcement.
  defp apply_run_summary(socket, snapshot) do
    {source, retained?} = RunSummaryPresenter.reconcile(socket.assigns.run_summary_source, snapshot)
    status_source = if retained?, do: snapshot, else: nil
    view = RunSummaryPresenter.present(source, retained?, status_source)

    socket
    |> assign(:run_summary_source, source)
    |> assign(:run_summary, view)
    |> assign(:run_summary_announcement, RunSummaryPresenter.announcement(view))
  end

  defp schedule_run_summary_flush do
    case Endpoint.config(:run_summary_flush_timer) do
      timer when is_function(timer, 3) -> timer.(self(), :flush_run_summary, @run_summary_flush_ms)
      _other -> Process.send_after(self(), :flush_run_summary, @run_summary_flush_ms)
    end
  end

  defp open_ticket_context(socket, %{identity: %TrackerIdentity{} = identity} = row) do
    socket = replace_ticket_context_subscription(socket, identity)
    detail = request_context(:ticket_detail_request_fun, &TicketDetailCache.request/1, identity)
    history = request_context(:ticket_history_request_fun, &TicketHistoryProvider.request/1, identity)

    socket
    |> assign(:ticket_context_identity, identity)
    |> assign(:ticket_context_row, row)
    |> assign_ticket_context(detail, history)
  end

  defp open_ticket_context(socket, _row), do: socket

  defp replace_ticket_context_subscription(socket, identity) do
    if same_identity?(socket.assigns.ticket_context_identity, identity) do
      subscribe_ticket_context(socket, identity)
    else
      socket
      |> unsubscribe_ticket_context()
      |> subscribe_ticket_context(identity)
    end
  end

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
          &subscribe_ticket_detail/1,
          identity
        )
        |> ensure_ticket_context_subscription(
          {key, :history},
          :ticket_history_subscribe_fun,
          &subscribe_ticket_history/1,
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

  defp unsubscribe_ticket_context(%{assigns: %{ticket_context_identity: %TrackerIdentity{} = identity}} = socket) do
    key = TrackerIdentity.github_key(identity)

    subscriptions =
      socket.assigns.ticket_context_subscriptions
      |> drop_ticket_context_subscription(
        {key, :detail},
        :ticket_detail_unsubscribe_fun,
        &unsubscribe_ticket_detail/1,
        identity
      )
      |> drop_ticket_context_subscription(
        {key, :history},
        :ticket_history_unsubscribe_fun,
        &unsubscribe_ticket_history/1,
        identity
      )

    assign(socket, :ticket_context_subscriptions, subscriptions)
  end

  defp unsubscribe_ticket_context(socket),
    do: assign(socket, :ticket_context_subscriptions, MapSet.new())

  defp drop_ticket_context_subscription(subscriptions, marker, config_key, default, identity) do
    if MapSet.member?(subscriptions, marker) do
      _result = call_context(config_key, default, identity)
      MapSet.delete(subscriptions, marker)
    else
      subscriptions
    end
  end

  defp subscribe_ticket_context_resets do
    _result =
      case Endpoint.config(:ticket_context_reset_subscribe_fun) do
        fun when is_function(fun, 0) -> fun.()
        _fun -> subscribe_default_ticket_context_resets()
      end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp subscribe_default_ticket_context_resets do
    :ok = Phoenix.PubSub.subscribe(Aiur.PubSub, TicketDetailCache.reset_topic())
    Phoenix.PubSub.subscribe(Aiur.PubSub, TicketHistoryProvider.reset_topic())
  end

  defp subscribe_ticket_detail(identity),
    do: Phoenix.PubSub.subscribe(Aiur.PubSub, TicketDetailCache.topic(identity))

  defp subscribe_ticket_history(identity),
    do: Phoenix.PubSub.subscribe(Aiur.PubSub, TicketHistoryProvider.topic(identity))

  defp unsubscribe_ticket_detail(identity),
    do: Phoenix.PubSub.unsubscribe(Aiur.PubSub, TicketDetailCache.topic(identity))

  defp unsubscribe_ticket_history(identity),
    do: Phoenix.PubSub.unsubscribe(Aiur.PubSub, TicketHistoryProvider.topic(identity))

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
        href: DecisionPath.inbox(:all, %{ticket: identifier}),
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

  defp open_conversation(socket, row, token, handle, snapshot) do
    socket
    |> replace_conversation_subscription(handle)
    |> assign(:conversation_handle, handle)
    |> assign(:conversation_identity, Map.get(row, :identity))
    |> assign(:conversation_row, row)
    |> assign(:conversation_origin_id, "units-conversation-#{token}")
    |> assign(:conversation_lifecycle, :active)
    |> assign(:conversation_snapshot, snapshot)
    |> present_conversation()
  end

  defp close_conversation(socket) do
    socket
    |> unsubscribe_conversation()
    |> assign(:conversation_drawer, nil)
    |> assign(:conversation_handle, nil)
    |> assign(:conversation_identity, nil)
    |> assign(:conversation_row, nil)
    |> assign(:conversation_origin_id, nil)
    |> assign(:conversation_lifecycle, :active)
    |> assign(:conversation_snapshot, nil)
  end

  defp present_conversation(socket) do
    view =
      ConversationPresenter.present(
        socket.assigns.conversation_row,
        socket.assigns.conversation_snapshot,
        socket.assigns.conversation_lifecycle
      )

    assign(socket, :conversation_drawer, view)
  end

  # Replace only the pinned generation's snapshot. A change for any other handle
  # is ignored so a replacement worker never appears under the old heading.
  defp maybe_update_conversation(
         %{assigns: %{conversation_handle: handle, conversation_lifecycle: :active}} = socket,
         %{generation_handle: handle} = snapshot
       )
       when is_binary(handle) do
    socket
    |> assign(:conversation_snapshot, snapshot)
    |> present_conversation()
  end

  defp maybe_update_conversation(socket, _snapshot), do: socket

  defp supersede_conversation(%{assigns: %{conversation_handle: handle}} = socket)
       when is_binary(handle) do
    socket
    |> assign(:conversation_lifecycle, :superseded)
    |> present_conversation()
  end

  defp supersede_conversation(socket), do: socket

  # On payload reload, transition truthfully: the row leaving scope freezes the
  # drawer as out-of-scope, a changed generation handle freezes it as superseded,
  # and an in-scope same-generation row refreshes only its metadata.
  defp refresh_conversation_row(%{assigns: %{conversation_lifecycle: :active, conversation_handle: handle}} = socket)
       when is_binary(handle) do
    rows = get_in(socket.assigns.payload, [:units, :snapshot, :rows]) || []
    identity = socket.assigns.conversation_identity

    case Enum.find(rows, &same_identity?(Map.get(&1, :identity), identity)) do
      nil ->
        socket
        |> assign(:conversation_lifecycle, :out_of_scope)
        |> present_conversation()

      row ->
        case conversation_handle(row) do
          ^handle ->
            socket
            |> assign(:conversation_row, row)
            |> present_conversation()

          _replaced ->
            socket
            |> assign(:conversation_lifecycle, :superseded)
            |> present_conversation()
        end
    end
  end

  defp refresh_conversation_row(socket), do: socket

  defp replace_conversation_subscription(socket, handle) do
    if socket.assigns.conversation_handle == handle do
      socket
    else
      socket
      |> unsubscribe_conversation()
      |> subscribe_conversation(handle)
    end
  end

  defp subscribe_conversation(socket, handle) do
    _result = call_conversation(:live_conversation_subscribe_fun, &LiveConversation.subscribe_handle/1, handle)
    socket
  end

  defp unsubscribe_conversation(%{assigns: %{conversation_handle: handle}} = socket)
       when is_binary(handle) do
    _result = call_conversation(:live_conversation_unsubscribe_fun, &LiveConversation.unsubscribe_handle/1, handle)
    socket
  end

  defp unsubscribe_conversation(socket), do: socket

  defp resolve_conversation(handle) do
    call_conversation(:live_conversation_resolve_fun, &LiveConversation.resolve/1, handle)
  end

  defp call_conversation(config_key, default, handle) do
    fun = Endpoint.config(config_key) || default
    fun.(handle)
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
    _kind, _reason -> {:error, :unavailable}
  end

  defp conversation_handle(%{live_conversation: %{generation_handle: handle}}) when is_binary(handle),
    do: handle

  defp conversation_handle(_row), do: nil

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
    |> maybe_put_query(:ticket, params["ticket"])
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

  defp send_operator_message(socket, _target, _key, ""), do: socket

  defp send_operator_message(socket, target, key, text) do
    case send_agent_message(target, text) do
      {:ok, _request_id} -> clear_chat_state(socket, key)
      {:error, reason} -> put_chat_error(socket, key, reason)
    end
  end

  defp send_agent_message(target, text) do
    case Endpoint.config(:agent_chat_send_fun) do
      fun when is_function(fun, 2) -> fun.(target, text)
      _fun -> AgentChat.send(target, text)
    end
  end

  defp pause_agent(target) do
    case Endpoint.config(:agent_chat_pause_fun) do
      fun when is_function(fun, 1) -> fun.(target)
      _fun -> AgentChat.pause(target)
    end
  end

  # --- Unit controls (DASH-005) --------------------------------------------

  # Resolve the row server-side by opaque token, recheck live capability, then
  # invoke DASH-004. Applied state is mirrored only from lifecycle evidence, so
  # this only records the request; it never mutates the row's lifecycle.
  defp request_unit_control(socket, token, action) do
    control = Map.get(socket.assigns.unit_controls, token)

    if UnitsControlPolicy.settled?(control) do
      resolve_unit_control_row(socket, token, action)
    else
      # A request for this unit is already pending; activation is idempotent.
      socket
    end
  end

  defp resolve_unit_control_row(socket, token, action) do
    catalog = Map.get(socket.assigns.payload, :units, %{})

    case UnitsPresenter.lookup(catalog, token) do
      {:ok, row} -> invoke_unit_control(socket, token, row, action)
      {:error, :not_found} -> socket
    end
  end

  defp invoke_unit_control(socket, token, row, action) do
    case UnitsControlPolicy.identifier(row) do
      nil ->
        put_unit_control(socket, token, %{action: action, status: :no_identity, identifier: nil})

      identifier ->
        recheck_and_invoke(socket, token, identifier, action)
    end
  end

  defp recheck_and_invoke(socket, token, identifier, action) do
    case unit_capabilities(identifier) do
      {:ok, capabilities} ->
        recheck_result(socket, token, identifier, action, UnitsControlPolicy.recheck(capabilities, action))

      {:error, reason} ->
        put_unit_control(socket, token, UnitsControlPolicy.settle_error(action, reason, identifier))
    end
  end

  defp recheck_result(socket, token, identifier, action, :ok),
    do: dispatch_unit_control(socket, token, identifier, action)

  defp recheck_result(socket, token, identifier, action, {:error, reason}),
    do: put_unit_control(socket, token, %{action: action, status: reason, identifier: identifier})

  defp dispatch_unit_control(socket, token, identifier, action) do
    case invoke_control_owner(action, identifier) do
      {:ok, result} ->
        # Subscribe to this unit's agent topic now, before its lifecycle
        # evidence can arrive, even if the row is not in the :running bucket the
        # periodic subscription sync tracks. The pending control is also unioned
        # into the sync set so the subscription survives reloads until it settles.
        socket
        |> put_unit_control(token, %{
          action: action,
          status: :requested,
          request_id: control_request_id(result),
          identifier: identifier
        })
        |> ensure_control_subscription(identifier)

      {:error, reason} ->
        put_unit_control(socket, token, UnitsControlPolicy.settle_error(action, reason, identifier))
    end
  end

  defp ensure_control_subscription(socket, identifier) do
    subscriptions = socket.assigns.unit_control_subscriptions

    if connected?(socket) and not MapSet.member?(subscriptions, identifier) do
      AgentPubSub.subscribe_agent(identifier)
      assign(socket, :unit_control_subscriptions, MapSet.put(subscriptions, identifier))
    else
      socket
    end
  end

  defp invoke_control_owner(:pause, identifier), do: pause_agent(identifier)
  defp invoke_control_owner(:resume, identifier), do: resume_agent(identifier)

  defp control_request_id(result) when is_integer(result), do: result
  defp control_request_id(_result), do: nil

  defp put_unit_control(socket, token, control_state) do
    assign(socket, :unit_controls, Map.put(socket.assigns.unit_controls, token, control_state))
  end

  defp resume_agent(identifier) do
    case Endpoint.config(:agent_chat_resume_fun) do
      fun when is_function(fun, 1) -> fun.(identifier)
      _fun -> AgentChat.resume(identifier)
    end
  end

  defp unit_capabilities(identifier) do
    case Endpoint.config(:agent_chat_capabilities_fun) do
      fun when is_function(fun, 1) -> fun.(identifier)
      _fun -> AgentChat.capabilities(identifier)
    end
  end

  defp apply_control_lifecycle(socket, payload) do
    identifier = get_in(payload, [:tracker_identity, :identifier])

    case find_control_token(socket.assigns.unit_controls, identifier) do
      {token, control} ->
        put_unit_control(socket, token, UnitsControlPolicy.apply_lifecycle(control, payload))

      nil ->
        socket
    end
  end

  defp find_control_token(controls, identifier) when is_binary(identifier) do
    Enum.find(controls, fn {_token, control} -> Map.get(control, :identifier) == identifier end)
  end

  defp find_control_token(_controls, _identifier), do: nil

  defp sync_unit_control_subscriptions(socket, false), do: socket

  defp sync_unit_control_subscriptions(socket, true) do
    desired = controllable_identifiers(socket)
    current = socket.assigns.unit_control_subscriptions

    Enum.each(MapSet.difference(desired, current), &AgentPubSub.subscribe_agent/1)
    Enum.each(MapSet.difference(current, desired), &AgentPubSub.unsubscribe_agent/1)

    assign(socket, :unit_control_subscriptions, desired)
  end

  # Subscribe to units that are controllable now, unioned with any unit that
  # still has an in-flight control, so a request whose row leaves the running
  # bucket mid-flight keeps its subscription until the lifecycle settles it.
  defp controllable_identifiers(socket) do
    running =
      socket.assigns.payload
      |> Map.get(:units, %{})
      |> unit_rows()
      |> Enum.filter(&(get_in(&1, [:runtime, :bucket]) == :running))
      |> Enum.map(&UnitsControlPolicy.identifier/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    MapSet.union(running, in_flight_control_identifiers(socket))
  end

  defp in_flight_control_identifiers(socket) do
    socket.assigns.unit_controls
    |> Enum.reject(fn {_token, control} -> UnitsControlPolicy.settled?(control) end)
    |> Enum.map(fn {_token, control} -> Map.get(control, :identifier) end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  # A changed or terminal row cancels stale in-flight UI intent rather than
  # targeting a replacement unit; settled states are left untouched.
  defp reconcile_unit_controls(%{assigns: %{unit_controls: controls}} = socket) when controls == %{},
    do: socket

  defp reconcile_unit_controls(socket) do
    catalog = Map.get(socket.assigns.payload, :units, %{})
    rows_by_token = Map.new(unit_rows(catalog), fn row -> {UnitsPresenter.row_token(row), row} end)

    reconciled =
      Map.new(socket.assigns.unit_controls, fn {token, control} ->
        {token, reconcile_control(control, Map.get(rows_by_token, token))}
      end)

    assign(socket, :unit_controls, reconciled)
  end

  defp reconcile_control(control, row) do
    if UnitsControlPolicy.settled?(control) or not stale_control_row?(row) do
      control
    else
      Map.put(control, :status, :state_changed)
    end
  end

  defp stale_control_row?(nil), do: true

  defp stale_control_row?(row),
    do: Map.get(row, :terminal?) == true or Map.get(row, :replacement_boundary?) == true

  defp unit_rows(%{snapshot: %{rows: rows}}) when is_list(rows), do: rows
  defp unit_rows(_catalog), do: []

  defp agent_log_target(%{tracker_identity: %TrackerIdentity{} = identity}), do: identity
  defp agent_log_target(%{issue_identifier: identifier}), do: to_string(identifier)

  defp agent_log_key(%{target_key: key}) when is_binary(key), do: key
  defp agent_log_key(%{issue_identifier: identifier}), do: to_string(identifier)
end
