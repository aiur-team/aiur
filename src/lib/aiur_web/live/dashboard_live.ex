defmodule AiurWeb.DashboardLive do
  @moduledoc """
  Phoenix LiveView shell for the Aiur Operator Control Center.
  """

  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias Aiur.AgentChat

  alias Aiur.AgentPubSub
  alias Aiur.BuildOrder.TicketDetail.State, as: TicketDetailState
  alias Aiur.BuildOrder.TicketDetailCache
  alias Aiur.BuildOrder.TicketHistory.Snapshot, as: TicketHistorySnapshot
  alias Aiur.BuildOrder.TicketHistoryProvider
  alias Aiur.CurrentRunMembership
  alias Aiur.CurrentRunOutcomeSnapshot
  alias Aiur.CurrentRunSummary
  alias Aiur.DecisionPubSub
  alias Aiur.ElevenLabs.Quota, as: ElevenLabsQuota
  alias Aiur.GitHub.Quota, as: GitHubQuota
  alias Aiur.LiveConversation
  alias Aiur.OpenTicketSource
  alias Aiur.Orchestrator.GlobalPause
  alias Aiur.Orchestrator.Slots
  alias Aiur.ProviderMeterRefresh
  alias Aiur.TicketActivity
  alias Aiur.TrackerIdentity
  alias Aiur.Usage.GroupedScopes
  alias Aiur.Usage.GroupedScopes.Scope
  alias Aiur.UsageAggregate
  alias AiurWeb.BuildOrder.TicketContextPresenter
  alias AiurWeb.Endpoint
  alias AiurWeb.FinancialData
  alias AiurWeb.FinancialDataAccess
  alias AiurWeb.ObservabilityPubSub

  alias AiurWeb.OperatorControlCenter.{
    AddAgentModal,
    AgentLogModal,
    AgentRoutingPreview,
    CapacityPresenter,
    ConversationDrawer,
    CurrentRunOutcomesPresenter,
    DashboardShell,
    DecisionEvents,
    DecisionInbox,
    DecisionPath,
    History,
    NavState,
    Overview,
    PayloadLoader,
    ProviderMeterSource,
    ProviderMetersPresenter,
    RouteRegistry,
    RunSummaryPresenter,
    RunSummaryStrip,
    TicketContext,
    TicketDetailModal,
    TicketsPanel,
    TicketsPresenter,
    UnitsControlPolicy,
    UnitsFilters,
    UnitsPresenter,
    UnitsTable,
    UnitsURL,
    UsageSummaryPresenter
  }

  alias AiurWeb.OperatorControlCenter.ConversationDrawer.Presenter, as: ConversationPresenter

  @runtime_tick_ms 1_000
  @github_quota_tick_ms 15_000
  # The ElevenLabs credit quota is a whole-account figure that moves far more
  # slowly than a per-request GitHub budget, so it refreshes on its own, longer
  # tick rather than riding GitHub's.
  @elevenlabs_quota_tick_ms 60_000
  @run_summary_flush_ms 250
  @usage_summary_flush_ms 250
  @usage_summary_max_age_ms 30_000
  @usage_drill_limit 25
  @usage_drill_dimensions ~w(by_provider by_ticket by_agent_family by_model by_account_generation)a

  # Matches the Tickets panel's own `maxlength`, so the control and the filter
  # agree on where a query stops.
  @max_ticket_query_length 128
  @provider_meters_flush_ms 250
  @current_run_outcomes_flush_ms 250
  @decision_filters [:all, :open, :blocking, :undelivered, :supervisor, :resolved, :superseded]
  # What "the operator is finished with it" means, mirrored from the retained
  # store's `history` lifecycle. A deferral belongs here: the Executor owns the
  # answer from that point, so the card leaves the operator's queue.
  @history_statuses [:decided, :acknowledged, :resolved, :dismissed, :expired, :deferred]
  @decision_events DecisionEvents.events()

  @impl true
  def mount(_params, _session, socket) do
    socket = NavState.assign_nav(socket)
    connected = connected?(socket)

    if connected do
      :ok = ObservabilityPubSub.subscribe()
      :ok = DecisionPubSub.subscribe()
      :ok = CurrentRunMembership.subscribe()
      :ok = CurrentRunSummary.subscribe()
      :ok = CurrentRunOutcomeSnapshot.subscribe()
      :ok = TicketActivity.subscribe()
      :ok = OpenTicketSource.subscribe()
      :ok = subscribe_ticket_context_resets()
    end

    payload = PayloadLoader.load(if connected, do: :fresh, else: :cached)

    socket =
      socket
      |> assign(:payload, payload)
      |> assign(:now, DateTime.utc_now())
      |> assign(:github_quota, github_quota_snapshot())
      |> assign(:elevenlabs_quota, elevenlabs_quota_snapshot())
      |> assign(:agent_log_modal, nil)
      |> assign(:drafts, %{})
      |> assign(:chat_errors, %{})
      |> assign(:decision_actions, %{})
      |> assign(:global_pause_error, nil)
      |> assign(:payload_reload_scheduled?, false)
      |> assign(:payload_reload_mode, :cached)
      |> assign(:writable, dashboard_writable?())
      |> assign(:decision_filter, :all)
      |> assign(:decision_page, empty_decision_page())
      |> assign(:decision_query, %{})
      |> init_history_rows()
      |> assign(:units_selection, UnitsURL.default_selection())
      |> assign(:unit_controls, %{})
      |> assign(:unit_control_subscriptions, MapSet.new())
      |> assign(:tickets_visible, TicketsPresenter.initial_reveal())
      |> assign_units_view()
      |> sync_unit_control_subscriptions(connected)
      |> assign(:capacity_input, "")
      |> assign(:capacity_feedback, nil)
      |> assign_initial_run_summary(connected)
      |> assign_initial_provider_meters(connected)
      |> assign_initial_current_run_outcomes(connected)
      |> assign_initial_usage_summary(connected)
      |> assign(:ticket_detail, nil)
      |> assign(:tickets_query, "")
      |> assign(:add_agent_modal, nil)
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

    if connected do
      schedule_runtime_tick()
      schedule_github_quota_tick()
      schedule_elevenlabs_quota_tick()
    end

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
     |> load_history(:first_page)
     |> assign_selected_decision(params["decision_id"])
     |> maybe_canonicalize_units_url(params)}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  def handle_info(:github_quota_tick, socket) do
    schedule_github_quota_tick()
    {:noreply, assign(socket, :github_quota, github_quota_snapshot())}
  end

  def handle_info(:elevenlabs_quota_tick, socket) do
    schedule_elevenlabs_quota_tick()
    {:noreply, assign(socket, :elevenlabs_quota, elevenlabs_quota_snapshot())}
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

  def handle_info({FinancialData, :updated, _identity} = message, socket) do
    socket =
      socket
      |> stash_usage_summary(message)
      |> schedule_provider_meters_reload(message)

    {:noreply, socket}
  end

  def handle_info(:flush_usage_summary, socket) do
    {:noreply, flush_usage_summary(socket)}
  end

  def handle_info(:flush_provider_meters, socket) do
    {:noreply, flush_provider_meters(socket)}
  end

  def handle_info({:current_run_outcome_snapshot_changed, snapshot}, socket) do
    {:noreply, stash_current_run_outcomes(socket, snapshot)}
  end

  def handle_info(:flush_current_run_outcomes, socket) do
    {:noreply, flush_current_run_outcomes(socket)}
  end

  def handle_info({:current_run_membership_health_changed, payload}, socket) do
    {:noreply, PayloadLoader.schedule(socket, {:event, {:membership_health, Map.get(payload, :generation)}})}
  end

  def handle_info({:ticket_activity_changed, payload}, socket) do
    {:noreply, PayloadLoader.schedule(socket, {:event, {:activity, Map.get(payload, :generation)}})}
  end

  def handle_info({:open_tickets_updated, change}, socket) do
    {:noreply, PayloadLoader.schedule(socket, {:event, {:open_tickets, Map.get(change, :generation)}})}
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
  def handle_event("toggle-nav", _params, socket), do: {:noreply, NavState.toggle(socket)}

  @impl true
  def handle_event("restore-nav", %{"collapsed" => collapsed}, socket),
    do: {:noreply, NavState.restore(socket, collapsed)}

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

  def handle_event("usage-drill-down", %{"dimension" => dimension}, socket) do
    {:noreply, open_usage_drill(socket, dimension)}
  end

  def handle_event("usage-drill-more", %{"dimension" => dimension, "cursor" => cursor}, socket) do
    {:noreply, page_usage_drill(socket, dimension, cursor)}
  end

  def handle_event("usage-drill-close", _params, socket) do
    {:noreply, assign(socket, usage_summary_drill: nil, usage_summary_drill_trigger: nil)}
  end

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

  def handle_event("select-all-units-filters", _params, socket) do
    {:noreply, push_patch(socket, to: units_path(UnitsPresenter.select_all_filters()))}
  end

  def handle_event("select-no-units-filters", _params, socket) do
    {:noreply, push_patch(socket, to: units_path(UnitsPresenter.select_no_filters()))}
  end

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

  def handle_event("inspect-ticket", %{"ticket" => token}, socket) when is_binary(token) do
    case TicketsPresenter.lookup(socket.assigns.tickets_view, token) do
      {:ok, row} -> {:noreply, assign(socket, :ticket_detail, row)}
      {:error, :not_found} -> {:noreply, socket}
    end
  end

  def handle_event("inspect-ticket", _params, socket), do: {:noreply, socket}

  def handle_event("close-ticket-detail", _params, socket), do: {:noreply, assign(socket, :ticket_detail, nil)}

  # Revealing is monotonic, and the count survives a re-projection: a tracker
  # poll must not collapse the table back under an operator part-way through
  # reading it. It anchors a row count, not a set of rows, so a ticket opened
  # upstream still enters at the top and pushes the last revealed row over the
  # edge — the same shift the untruncated table always had, one batch lower.
  def handle_event("show-more-tickets", _params, socket) do
    {:noreply, assign(socket, :tickets_visible, TicketsPresenter.reveal_more(socket.assigns.tickets_visible))}
  end

  # Filtering is a server round trip per debounced change rather than a client
  # hook over the loaded rows: the panel reveals its table in batches, so a
  # client-side filter would only ever see the revealed ones, and the operator
  # would be told a ticket does not exist when it merely has not been revealed.
  def handle_event("search-tickets", %{"query" => query}, socket) when is_binary(query) do
    # Clamped server-side as well as in the input: a filter over the whole
    # backlog is real work, and a pasted plan or stack trace would otherwise buy
    # seconds of it inside the socket process that serves the rest of the page.
    {:noreply, socket |> assign(:tickets_query, String.slice(query, 0, @max_ticket_query_length)) |> assign_tickets_panel_view()}
  end

  def handle_event("search-tickets", _params, socket), do: {:noreply, socket}

  def handle_event("clear-ticket-search", _params, socket) do
    {:noreply, socket |> assign(:tickets_query, "") |> assign_tickets_panel_view()}
  end

  def handle_event("open-add-agent", %{"ticket" => token}, socket) when is_binary(token) do
    case TicketsPresenter.lookup(socket.assigns.tickets_view, token) do
      {:ok, row} -> {:noreply, assign(socket, :add_agent_modal, add_agent_modal(row))}
      {:error, :not_found} -> {:noreply, socket}
    end
  end

  def handle_event("open-add-agent", _params, socket), do: {:noreply, socket}

  def handle_event("close-add-agent", _params, socket), do: {:noreply, assign(socket, :add_agent_modal, nil)}

  def handle_event("change-add-agent", params, %{assigns: %{add_agent_modal: %{} = modal}} = socket) do
    {:noreply, assign(socket, :add_agent_modal, change_add_agent(modal, params))}
  end

  def handle_event("change-add-agent", _params, socket), do: {:noreply, socket}

  def handle_event("confirm-add-agent", _params, %{assigns: %{add_agent_modal: %{} = modal}} = socket) do
    handle_writable_event(socket, fn ->
      modal = confirm_add_agent(modal)
      {:noreply, socket |> refresh_open_tickets(modal.result) |> assign(:add_agent_modal, modal)}
    end)
  end

  def handle_event("confirm-add-agent", _params, socket), do: {:noreply, socket}

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
    decision_id = params["decision_id"] || params["decision-id"]
    reload = &(&1 |> reload_after_action() |> promote_history_row(decision_id))

    handle_writable_event(socket, fn ->
      {:noreply, DecisionEvents.handle(event, params, socket, reload)}
    end)
  end

  def handle_event("load-more-history", _params, socket) do
    {:noreply, load_history(socket, :next_page)}
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

  # Provider usage is polled from a rate-limited endpoint, so it is polled only
  # while a surface is actually being watched. Registration is by pid and
  # monitored on the other side, so a closed tab withdraws itself.
  def handle_event("usage-watch-start", _params, socket) do
    ProviderMeterRefresh.watching_started()
    {:noreply, socket}
  end

  def handle_event("usage-watch-stop", _params, socket) do
    ProviderMeterRefresh.watching_stopped()
    {:noreply, socket}
  end

  def handle_event("toggle-global-pause", _params, socket) do
    handle_writable_event(socket, fn -> {:noreply, toggle_global_pause(socket)} end)
  end

  defp toggle_global_pause(socket) do
    target = not global_paused?(socket.assigns.payload)

    case GlobalPause.set_global_pause(capacity_orchestrator(), target, "dashboard") do
      {:ok, _status} ->
        # The orchestrator broadcasts an observability update on success; reload
        # so the nav toggle reflects the new state even if the broadcast is missed.
        socket
        |> assign(:global_pause_error, nil)
        |> reload_after_action()

      {:error, {:global_pause_persistence_failed, _reason}} ->
        assign(
          socket,
          :global_pause_error,
          "Global pause was not changed because its state could not be persisted. The daemon remains in its previous state; check the daemon log and retry."
        )

      {:error, reason} ->
        assign(socket, :global_pause_error, "Global pause could not be changed: #{inspect(reason)}")
    end
  end

  defp global_paused?(payload) when is_map(payload) do
    payload |> Map.get(:fleet, %{}) |> Map.get(:globally_paused, false) == true
  end

  defp global_paused?(_payload), do: false

  defp global_pause_provenance(payload) do
    case get_in(payload, [:fleet, :global_pause]) do
      %{source: source, paused_at: paused_at} when is_binary(source) and is_binary(paused_at) ->
        "Set by #{source} at #{paused_at}. "

      %{source: source} when is_binary(source) ->
        "Set by #{source}. "

      _ ->
        ""
    end
  end

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
      |> Map.put_new(:history_rows, [])
      |> Map.put_new(:history_ids, MapSet.new())
      |> Map.put_new(:history_total, nil)
      |> Map.put_new(:history_has_more, false)
      |> Map.put_new(:history_health, :ok)
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
      |> then(&Map.put_new(&1, :units_count_label, units_count_label(&1.units_view)))
      |> Map.put_new(:tickets_view, TicketsPresenter.normalize(Map.get(assigns.payload, :tickets)))
      |> Map.put_new(:tickets_visible, TicketsPresenter.initial_reveal())
      |> Map.put_new(:tickets_query, "")
      |> then(&Map.put_new(&1, :tickets_panel_view, TicketsPresenter.search(&1.tickets_view, &1.tickets_query)))
      |> Map.put_new(:ticket_detail, nil)
      |> Map.put_new(:add_agent_modal, nil)
      |> Map.put_new(:capacity_view, CapacityPresenter.present(capacity_facts(assigns.payload)))
      |> Map.put_new(:capacity_input, "")
      |> Map.put_new(:capacity_feedback, nil)
      |> Map.put_new(:run_summary, RunSummaryPresenter.present(nil))
      |> Map.put_new(:run_summary_announcement, nil)
      |> Map.put_new(:usage_summary, UsageSummaryPresenter.present(nil))
      |> Map.put_new(:usage_summary_announcement, nil)
      |> Map.put_new(:usage_summary_drill, nil)
      |> Map.put_new(:usage_summary_drill_trigger, nil)
      |> then(&Map.put_new(&1, :provider_meters_view, ProviderMetersPresenter.present(financial_data_capability(&1))))
      |> Map.put_new(:provider_meters_announcement, nil)
      |> Map.put_new(:github_quota, %{state: :unknown, windows: %{}, attribution: [], coverage: nil, backoffs: []})
      |> Map.put_new(:elevenlabs_quota, %{state: :unconfigured, window: nil, failure: nil, observed_at: nil})
      |> Map.put_new(:current_run_outcomes, CurrentRunOutcomesPresenter.present(nil))
      |> Map.put_new(:current_run_outcomes_announcement, nil)
      |> Map.put_new(:current_route, RouteRegistry.current_route(Map.get(assigns, :live_action)))

    ~H"""
    <DashboardShell.dashboard_shell
      route={@current_route}
      routes={RouteRegistry.routes(@payload.analytics)}
      tracker_kind={tracker_kind()}
      agent_kind={agent_kind()}
      nav_counts={nav_counts(@units_view, @retained_counts)}
      nav_collapsed={@nav_collapsed}
      globally_paused={global_paused?(@payload)}
      writable={@writable}
      fleet_freshness={@payload.fleet[:snapshot_freshness]}
    >
      <:banner>
        <div :if={@global_pause_error} class="readonly-banner global-pause-error" role="alert" aria-live="assertive">
          <span aria-hidden="true">⚠</span>
          <span>{@global_pause_error}</span>
        </div>
        <div :if={global_paused?(@payload)} class="readonly-banner global-pause-banner" role="alert" aria-live="polite">
          <span aria-hidden="true">⏸</span>
          <span><b>Aiur is globally paused.</b> {global_pause_provenance(@payload)}Run <code>aiurdev resume</code> with no ticket ID to lift the global pause.</span>
        </div>
        <Overview.decisions_banner decisions={@payload.decisions} retained_counts={@retained_counts} />
      </:banner>

      <Overview.error error={@payload.fleet[:error]} />

      <div :if={@live_action in [:decisions, :decision]} class="control-panel">
        <div :if={not is_nil(@selected_decision) and partial_detail?(@selected_decision_health)} class="readonly-banner" role="status" aria-live="polite">
          <span aria-hidden="true">◉</span>
          <span><b>Partial Command data.</b> Some of this detail may be missing.</span>
        </div>
        <div :if={@live_action == :decision and is_nil(@selected_decision)} class="error-card" role="alert">
          <h2>{selected_decision_error_title(@selected_decision_status)}</h2>
          <p>{selected_decision_error_message(@selected_decision_status, @selected_decision_id)}</p>
        </div>
        <DecisionInbox.decision_inbox
          decisions={Enum.reject(@decision_page.decisions, &(&1.decision_id == @selected_decision_id))}
          selected_decision={inbox_selected_decision(@selected_decision, @history_rows)}
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
          history_total={@history_total}
        />
        <History.history
          rows={@history_rows}
          loaded={MapSet.size(@history_ids)}
          total={@history_total}
          has_more={@history_has_more}
          provider_health={@history_health}
          expanded_id={history_expanded_id(@selected_decision, @history_rows)}
          expanded_decision={@selected_decision}
          history={@payload.history}
          action_state={history_action_state(@decision_actions, @selected_decision_id)}
          writable={@writable}
          filter={@decision_filter}
          query={@decision_query}
        />
      </div>

      <div
        :if={@live_action not in [:decisions, :decision]}
        id="usage-watch"
        phx-hook="UsageWatch"
        class="control-panel"
      >
        <RunSummaryStrip.run_summary_strip
          run={@run_summary}
          usage={@usage_summary}
          meters={@provider_meters_view}
          github_quota={@github_quota}
          elevenlabs_quota={@elevenlabs_quota}
          now={@now}
        />

        <section class="section-card units-card" aria-labelledby="route-title">
          <p id="units-status" class="sr-only" role="status" aria-live="polite" aria-atomic="true">
            {@units_announcement}
          </p>
          <RunSummaryStrip.run_summary_compact
            run={@run_summary}
            usage={@usage_summary}
            meters={@provider_meters_view}
            now={@now}
          />
          <div class="rs-group-head units-group-head">
            <span class="rs-group-title" id="units-agents-title">Agents</span>
            <span class="rs-group-count">{@units_count_label}</span>
          </div>
          <UnitsFilters.units_filters
            selection={@units_selection}
            counts={@units_view[:counts] || %{}}
            count_status={@units_view[:count_status] || :unavailable}
          />
          <UnitsTable.units_table view={@units_view} now={@now} controls={@unit_controls} writable={@writable} />
        </section>

        <%!-- The searched view, so the reveal batches and counts the matches
        rather than the whole backlog behind them. --%>
        <TicketsPanel.tickets_panel view={@tickets_panel_view} visible={@tickets_visible} />
      </div>

      <AgentLogModal.agent_log_modal
        :if={is_nil(@conversation_drawer)}
        modal={@agent_log_modal}
        writable={@writable}
        drafts={@drafts}
        errors={@chat_errors}
      />
      <TicketDetailModal.ticket_detail_modal ticket={@ticket_detail} />
      <AddAgentModal.add_agent_modal modal={@add_agent_modal} writable={@writable} />
      <TicketContext.ticket_context
        :if={@ticket_context}
        id="units-ticket-context"
        context={@ticket_context}
        close_event="close-ticket-context"
        fallback_focus_id="route-title"
      />
      <ConversationDrawer.conversation_drawer
        :if={@conversation_drawer}
        id="units-conversation-drawer"
        view={@conversation_drawer}
        composer={@agent_log_modal}
        writable={@writable}
        drafts={@drafts}
        errors={@chat_errors}
        close_event="close-conversation"
        fallback_focus_id="route-title"
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
    |> load_history(:head)
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
    do: "#{decision_id} may exist in a part we cannot read, so it cannot be reported as missing. The overview is still available."

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
      awaiting: nil,
      awaiting_blocking: nil,
      deferred: nil,
      health: %{status: :unavailable, label: "Command counts unavailable"}
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

  # Nav badges surface live attention counts: active units and open Commands.
  # Only real, positive integers are emitted; anything unknown is omitted so the
  # nav never fabricates a count.
  defp nav_counts(units_view, retained_counts) do
    %{}
    |> put_nav_count(:units, get_in(units_view, [:counts, :active]))
    |> put_nav_count(:commands, Map.get(retained_counts || %{}, :awaiting))
  end

  defp put_nav_count(counts, key, value) when is_integer(value) and value > 0,
    do: Map.put(counts, key, value)

  defp put_nav_count(counts, _key, _value), do: counts

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
    tickets_view = socket.assigns.payload |> Map.get(:tickets) |> TicketsPresenter.normalize()

    socket
    |> assign(:units_view, view)
    |> assign(:units_announcement, UnitsPresenter.announcement(view))
    |> assign(:units_count_label, units_count_label(view))
    |> assign(:tickets_view, tickets_view)
    |> assign_tickets_panel_view()
  end

  # The unfiltered projection stays in `tickets_view` and the panel renders the
  # searched one. Lookups — the add-agent modal, the ticket-context refresh —
  # then keep resolving a row the current query happens to hide, so a ticket
  # already open on screen does not go dead the moment the operator types.
  defp assign_tickets_panel_view(socket) do
    # Reached during mount before the query default is assigned, so the query is
    # read defensively: no search yet means the unfiltered projection.
    query = Map.get(socket.assigns, :tickets_query, "")
    assign(socket, :tickets_panel_view, TicketsPresenter.search(socket.assigns.tickets_view, query))
  end

  # The modal opens on the routing the dispatcher would have applied, so the
  # operator confirms a prediction rather than filling in a blank form.
  #
  # The model falls back to `resolved_model` only when routing named no model at all.
  # `model` is the *requested* model and is `nil` whenever routing names just a
  # backend, which would preselect "Backend default" and hide the model that is
  # actually going to run — the prediction the Tickets table used to print in a
  # "Would route to" column, and which now lives only here.
  #
  # The requested model is preferred over the resolved one so a family alias stays
  # an alias. `CodingAgent.override_labels/0` seeds aliases ahead of pinned versions
  # because "a pinned tag expires with its version"; preselecting `gpt-5.6-sol` for a
  # `codex:sol` routing entry would write that expiry onto the ticket and strand it
  # on 5.6 while every untouched ticket follows the alias forward.
  #
  # `normalize_selection/1` clamps whichever value wins to the backend's seedable
  # vocabulary, so a model aiur does not list falls back to the backend default.
  defp add_agent_modal(row) do
    routing = row.routing

    selection = %{
      backend: routing.backend,
      model: routing.model || routing.resolved_model,
      effort: routing.effort,
      complexity: routing.complexity
    }

    build_add_agent_modal(row, selection)
  end

  defp change_add_agent(modal, params) do
    backend = blank_to_nil(params["backend"]) || modal.selection.backend

    # A new backend invalidates the model and effort vocabularies, so a stale
    # selection is dropped rather than carried onto a backend that rejects it.
    # `normalize_selection/1` then clamps every field to what the daemon can
    # honour, because all four arrive from the browser.
    carry_over? = backend == modal.selection.backend

    selection = %{
      backend: backend,
      model: carry_over? && blank_to_nil(params["model"]),
      effort: carry_over? && blank_to_nil(params["effort"]),
      complexity: parse_complexity(params["complexity"])
    }

    build_add_agent_modal(modal, selection)
  end

  defp build_add_agent_modal(row, selection) do
    selection = AgentRoutingPreview.normalize_selection(selection)
    labels = Map.get(row, :labels, [])

    %{
      token: row.token,
      identifier: row.identifier,
      title: row.title,
      identity: Map.get(row, :identity),
      routing: Map.get(row, :routing, %{available?: false}),
      selection: selection,
      options: AgentRoutingPreview.options(selection.backend),
      labels: labels,
      plan: AgentRoutingPreview.plan(selection, labels),
      result: nil
    }
  end

  defp confirm_add_agent(modal) do
    Map.put(modal, :result, apply_label_plan(modal.identifier, modal.plan))
  end

  defp apply_label_plan(_identifier, %{add: [], remove: []}), do: {:error, :no_labels}

  # Removals run first so a replaced `complexity:`/`model:` label cannot outrank
  # the new one, and every applied change is reported even when a later call
  # fails — the operator has to know the ticket is half-labelled.
  defp apply_label_plan(identifier, %{add: add, remove: remove}) do
    with {:ok, removed} <- apply_labels(identifier, remove, :remove_label),
         {:ok, added} <- apply_labels(identifier, add, :add_label) do
      {:ok, added ++ removed}
    else
      {:error, applied, reason} -> {:partial, applied, reason}
    end
  end

  defp apply_labels(identifier, labels, action) do
    fun = Endpoint.config(:add_agent_fun) || (&apply(Aiur.Tracker, &3, [&1, &2]))

    Enum.reduce_while(labels, {:ok, []}, fn label, {:ok, applied} ->
      case safe_label_call(fun, identifier, label, action) do
        :ok -> {:cont, {:ok, [label | applied]}}
        {:ok, _result} -> {:cont, {:ok, [label | applied]}}
        {:error, reason} -> {:halt, {:error, applied, reason}}
        other -> {:halt, {:error, applied, other}}
      end
    end)
  end

  defp safe_label_call(fun, identifier, label, action) do
    cond do
      is_function(fun, 3) -> fun.(identifier, label, action)
      is_function(fun, 2) -> fun.(identifier, label)
      true -> {:error, :unavailable}
    end
  rescue
    _error -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  # Confirming changed the tracker, so the panel's labels and its routing
  # prediction are both stale until the poller catches up. Ask it to re-read now.
  defp refresh_open_tickets(socket, result) when elem(result, 0) in [:ok, :partial] do
    OpenTicketSource.refresh()
    Aiur.Orchestrator.request_refresh(capacity_orchestrator())
    reload_after_action(socket)
  rescue
    _error -> socket
  catch
    _kind, _reason -> socket
  end

  defp refresh_open_tickets(socket, _result), do: socket

  defp parse_complexity(value) do
    case blank_to_nil(value) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {complexity, ""} when complexity in 1..5 -> complexity
          _other -> nil
        end
    end
  end

  defp blank_to_nil(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))
  defp blank_to_nil(_value), do: nil

  # The Agents panel counts what the panel actually shows, so a filtered view
  # never claims a fleet size the table below it does not contain. A partial
  # catalog is qualified rather than rounded down to a confident number.
  defp units_count_label(view) do
    case Map.get(view, :count_status, :unavailable) do
      :unavailable -> "agents unavailable"
      :partial -> "at least #{agent_phrase(view)}"
      _exact -> agent_phrase(view)
    end
  end

  defp agent_phrase(view) do
    case view |> Map.get(:rows, []) |> length() do
      1 -> "1 agent"
      count -> "#{count} agents"
    end
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

  # --- DASH-031 authenticated usage and cost summary -----------------------

  # On an authorized mount/reconnect, fetch a bounded snapshot and subscribe to
  # daemon-owned change notifications. A denied connection renders the value-free
  # locked view and never queries, subscribes to, caches, or assigns a protected
  # usage, cost, generation, coverage, tier, or drill-down fact.
  defp assign_initial_usage_summary(socket, connected) do
    socket =
      socket
      |> assign(:usage_summary_source, nil)
      |> assign(:usage_summary_pending, nil)
      |> assign(:usage_summary_flush_scheduled?, false)
      |> assign(:usage_summary_drill, nil)
      |> assign(:usage_summary_drill_trigger, nil)

    case {connected, authorized_context(socket)} do
      {true, {:ok, context}} ->
        _ = safe_usage_subscribe(context)
        refresh_usage_summary(socket, nil)

      {_connected, :locked} ->
        assign_locked_usage_summary(socket)

      {false, {:ok, _context}} ->
        # Authorized but not yet connected: defer the protected fetch to the
        # connected mount and show the bounded loading view.
        assign_usage_view(socket, UsageSummaryPresenter.present(nil))
    end
  end

  # The single capability gate every protected usage call passes through. A
  # locked capability or an absent verified context yields `:locked`; no
  # protected fetch, subscribe, or reload is reachable outside this gate.
  defp authorized_context(socket) do
    capability = Map.get(socket.assigns, :financial_data_capability, %{})

    case {Map.get(capability, :state), FinancialDataAccess.context(socket)} do
      {:authorized, %FinancialDataAccess.Context{} = context} -> {:ok, context}
      _denied -> :locked
    end
  end

  # Fetch (message == nil) or revalidate-and-reload (message from a delivered
  # update) one protected usage snapshot, then present it. An
  # authentication_required result is a hard demotion to locked, never stale LKG.
  defp refresh_usage_summary(socket, message) do
    case authorized_context(socket) do
      {:ok, context} -> apply_usage_summary(socket, fetch_usage_result(socket, context, message))
      :locked -> demote_usage_to_locked(socket)
    end
  end

  defp fetch_usage_result(socket, context, message) do
    case current_run_id(socket) do
      run_id when is_binary(run_id) ->
        {:ok, scope} = Scope.this_run(run_id)
        key = usage_cache_key(scope)
        loader = fn -> load_usage_snapshot(scope) end

        case message do
          nil ->
            FinancialData.fetch_usage_grouping(FinancialData, context, key, @usage_summary_max_age_ms, loader)

          message ->
            FinancialData.reload(FinancialData, context, message, :usage_grouping, key, @usage_summary_max_age_ms, loader)
        end

      _no_run ->
        {:ok, blank_usage_snapshot(:known_empty)}
    end
  rescue
    _error -> {:error, :provider_unavailable}
  catch
    :exit, _reason -> {:error, :provider_unavailable}
  end

  defp apply_usage_summary(socket, {:ok, snapshot}) do
    {source, retained?} = UsageSummaryPresenter.reconcile(socket.assigns.usage_summary_source, snapshot)
    status_source = if retained?, do: snapshot, else: nil

    view =
      UsageSummaryPresenter.present(source,
        retained?: retained?,
        status_source: status_source,
        tier_facts: usage_tier_facts(source)
      )

    socket
    |> assign(:usage_summary_source, source)
    |> assign_usage_view(view)
    |> refresh_open_drill()
  end

  defp apply_usage_summary(socket, {:error, :authentication_required}) do
    demote_usage_to_locked(socket)
  end

  defp apply_usage_summary(socket, {:error, _reason}) do
    # A degraded scope/provider preserves the qualified last-known-good (the
    # presenter retains a same-scope healthy snapshot as stale) and never resets
    # usage or cost to zero.
    apply_usage_summary(socket, {:ok, unavailable_usage_snapshot(usage_scope_public(socket))})
  end

  # A hard demotion: clear every protected assign and render the value-free
  # locked view. Used when a mid-session configuration change revokes access.
  defp demote_usage_to_locked(socket) do
    socket
    |> assign(:usage_summary_source, nil)
    |> assign(:usage_summary_pending, nil)
    |> assign(:usage_summary_drill, nil)
    |> assign(:usage_summary_drill_trigger, nil)
    |> assign_locked_usage_summary()
  end

  defp assign_locked_usage_summary(socket) do
    capability = Map.get(socket.assigns, :financial_data_capability, %{})
    assign_usage_view(socket, UsageSummaryPresenter.locked_view(capability))
  end

  defp assign_usage_view(socket, view) do
    socket
    |> assign(:usage_summary, view)
    |> assign(:usage_summary_announcement, UsageSummaryPresenter.announcement(view))
  end

  # Coalesce bursts of daemon change notifications: keep only the latest pending
  # signal and reload once per debounce window so renders and announcements stay
  # bounded and focus-preserving.
  defp stash_usage_summary(socket, message) do
    socket = assign(socket, :usage_summary_pending, message)

    if socket.assigns.usage_summary_flush_scheduled? do
      socket
    else
      schedule_usage_summary_flush()
      assign(socket, :usage_summary_flush_scheduled?, true)
    end
  end

  defp flush_usage_summary(socket) do
    socket = assign(socket, :usage_summary_flush_scheduled?, false)

    case socket.assigns.usage_summary_pending do
      nil -> socket
      message -> socket |> assign(:usage_summary_pending, nil) |> refresh_usage_summary(message)
    end
  end

  defp schedule_usage_summary_flush do
    case Endpoint.config(:usage_summary_flush_timer) do
      timer when is_function(timer, 3) -> timer.(self(), :flush_usage_summary, @usage_summary_flush_ms)
      _other -> Process.send_after(self(), :flush_usage_summary, @usage_summary_flush_ms)
    end
  end

  # The loader runs server-side inside the protected facade; the raw cells never
  # leave the daemon — the grouped-scope layer reduces them to a bounded snapshot
  # before anything reaches the browser.
  defp load_usage_snapshot(scope) do
    UsageAggregate.cells_snapshot() |> GroupedScopes.project(scope, currency: "USD")
  end

  # Scope authority is the current run's opaque identity, never inferred from
  # labels, visible rows, URL text, or active workers. The explicit build scope
  # arrives later from DASH-023; this ticket renders `this_run` only.
  defp current_run_id(socket) do
    case Map.get(socket.assigns, :run_summary_source) do
      %{run: %{id: id}} when is_binary(id) and id != "" -> id
      _other -> nil
    end
  end

  # Fold the scope and the current aggregate generation into the cache key so a
  # new projection generation always misses the bounded authenticated cache.
  defp usage_cache_key(scope) do
    {Scope.public(scope), usage_aggregate_generation()}
  end

  defp usage_aggregate_generation do
    UsageAggregate.snapshot().generation
  rescue
    _error -> :unknown
  catch
    :exit, _reason -> :unknown
  end

  # Tier facts join only on an exact known (provider, backend, generation). The
  # LiveView has no by-generation provider-meter binding today (the meter store
  # is keyed by a live auth binding), so tier facts are empty here and every
  # generation renders explicitly unjoined. The presenter join logic is exercised
  # by fixtures; a by-generation meter seam is future work.
  defp usage_tier_facts(_source), do: %{}

  defp usage_scope_public(socket) do
    case Map.get(socket.assigns, :usage_summary_source) do
      %{scope: scope} when is_map(scope) -> scope
      _other -> %{kind: :this_run, run_id: nil, tickets: [], rejected_tickets: 0, status: :empty}
    end
  end

  # A value-carrying grouped-snapshot shell for the empty and degraded states.
  # Unknown cost is named unknown here, never a synthetic zero total.
  defp blank_usage_snapshot(state) do
    %{
      schema_version: 1,
      state: state,
      scope: %{kind: :this_run, run_id: nil, tickets: [], rejected_tickets: 0, status: :empty},
      currency: "USD",
      tokens: %{},
      provider_reported_estimate: %{by_currency: %{}},
      api_equivalent_estimate: %{rollup: %{}, coverage: %{known: 0, unknown: 0, reasons: [], status: :none}},
      contributors: %{by_auth_mode: []},
      reconciliation: %{reconciled?: true, by_dimension: %{}},
      tier_join_keys: [],
      coverage: %{source: %{}, unknown_attribution: %{}, api_equivalent: %{known: 0, unknown: 0, reasons: [], status: :none}},
      retained_interval: %{earliest: nil, latest: nil, status: :missing},
      health: :healthy,
      freshness: %{status: :empty}
    }
  end

  defp unavailable_usage_snapshot(scope) do
    blank_usage_snapshot(:unavailable)
    |> Map.put(:scope, scope)
    |> Map.put(:health, {:unavailable, :provider_unavailable})
    |> Map.put(:freshness, %{status: :unavailable})
  end

  defp safe_usage_subscribe(context) do
    FinancialData.subscribe(context)
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  # Bounded, keyboard/touch drill-down. Only an authorized connection with a
  # loaded snapshot may open or page a dimension; a denied connection is a no-op.
  defp open_usage_drill(socket, dimension) do
    with {:ok, _context} <- authorized_context(socket),
         dim when not is_nil(dim) <- usage_drill_dimension(dimension),
         %{} = source <- Map.get(socket.assigns, :usage_summary_source) do
      page = UsageSummaryPresenter.drill_down(source, dim, limit: @usage_drill_limit)

      socket
      |> assign(:usage_summary_drill, page)
      |> assign(:usage_summary_drill_trigger, Atom.to_string(dim))
    else
      _denied_or_missing -> socket
    end
  end

  defp page_usage_drill(socket, dimension, cursor) do
    with {:ok, _context} <- authorized_context(socket),
         dim when not is_nil(dim) <- usage_drill_dimension(dimension),
         %{} = source <- Map.get(socket.assigns, :usage_summary_source),
         %{dimension: ^dim} = existing <- Map.get(socket.assigns, :usage_summary_drill),
         cursor when is_integer(cursor) <- parse_cursor(cursor) do
      page = UsageSummaryPresenter.drill_down(source, dim, cursor: cursor, limit: @usage_drill_limit)
      assign(socket, :usage_summary_drill, %{page | items: existing.items ++ page.items})
    else
      _denied_or_missing -> socket
    end
  end

  # Keep an open drill-down consistent with the current snapshot: when a live
  # update replaces the source, re-page the same dimension over the fresh source
  # for the number of rows already shown, so stale contributor rows never mix
  # with a newer projection.
  defp refresh_open_drill(socket) do
    case {Map.get(socket.assigns, :usage_summary_drill), Map.get(socket.assigns, :usage_summary_source)} do
      {%{dimension: dim} = existing, %{} = source} ->
        shown = max(length(existing.items), @usage_drill_limit)
        page = UsageSummaryPresenter.drill_down(source, dim, cursor: 0, limit: shown)
        assign(socket, :usage_summary_drill, page)

      _no_open_drill ->
        socket
    end
  end

  defp usage_drill_dimension(dimension) when is_binary(dimension) do
    Enum.find(@usage_drill_dimensions, &(Atom.to_string(&1) == dimension))
  end

  defp usage_drill_dimension(_dimension), do: nil

  defp parse_cursor(cursor) when is_integer(cursor) and cursor >= 0, do: cursor

  defp parse_cursor(cursor) when is_binary(cursor) do
    case Integer.parse(cursor) do
      {value, ""} when value >= 0 -> value
      _other -> nil
    end
  end

  defp parse_cursor(_cursor), do: nil

  # Provider meter cards read protected snapshots only through the DASH-021
  # facade. An authorized connection fetches once on mount and subscribes to
  # payload-free updates; a locked connection never obtains a context, never
  # queries, and never subscribes, so its card renders the content-free locked
  # state.
  defp assign_initial_provider_meters(socket, connected) do
    capability = financial_data_capability(socket.assigns)

    snapshots =
      if connected and authorized?(capability) do
        context = FinancialDataAccess.context(socket)
        _subscription = subscribe_provider_meters(context)
        load_provider_meters(context)
      else
        %{}
      end

    socket
    |> assign(:provider_meter_snapshots, snapshots)
    |> assign(:provider_meters_pending_message, nil)
    |> assign(:provider_meters_flush_scheduled?, false)
    |> apply_provider_meters()
  end

  # Coalesce bursts of payload-free facade updates: schedule one flush per
  # debounce window so protected re-reads and screen-reader announcements stay
  # bounded and isolated from the render loop.
  defp schedule_provider_meters_reload(socket, message) do
    socket = assign(socket, :provider_meters_pending_message, message)

    if socket.assigns.provider_meters_flush_scheduled? do
      socket
    else
      schedule_provider_meters_flush()
      assign(socket, :provider_meters_flush_scheduled?, true)
    end
  end

  defp flush_provider_meters(socket) do
    socket = assign(socket, :provider_meters_flush_scheduled?, false)
    capability = financial_data_capability(socket.assigns)
    message = socket.assigns.provider_meters_pending_message

    if authorized?(capability) and not is_nil(message) do
      context = FinancialDataAccess.context(socket)
      snapshots = reload_provider_meters(context, message)

      socket
      |> assign(:provider_meter_snapshots, snapshots)
      |> assign(:provider_meters_pending_message, nil)
      |> apply_provider_meters()
    else
      socket
    end
  end

  defp apply_provider_meters(socket) do
    capability = financial_data_capability(socket.assigns)
    view = ProviderMetersPresenter.present(capability, socket.assigns.provider_meter_snapshots)

    socket
    |> assign(:provider_meters_view, view)
    |> assign(:provider_meters_announcement, ProviderMetersPresenter.announcement(view))
  end

  defp subscribe_provider_meters(context), do: provider_meter_source().subscribe(context)
  defp load_provider_meters(context), do: provider_meter_source().load(context)
  defp reload_provider_meters(context, message), do: provider_meter_source().reload(context, message)

  defp provider_meter_source do
    case Endpoint.config(:provider_meter_source) do
      module when is_atom(module) and not is_nil(module) -> module
      _other -> ProviderMeterSource
    end
  end

  defp schedule_provider_meters_flush do
    case Endpoint.config(:provider_meters_flush_timer) do
      timer when is_function(timer, 3) -> timer.(self(), :flush_provider_meters, @provider_meters_flush_ms)
      _other -> Process.send_after(self(), :flush_provider_meters, @provider_meters_flush_ms)
    end
  end

  defp financial_data_capability(assigns), do: Map.get(assigns, :financial_data_capability) || FinancialDataAccess.locked_capability()

  defp authorized?(%{state: :authorized}), do: true
  defp authorized?(_capability), do: false

  # Read the current DASH-032 outcome snapshot on mount/reconnect. On the dead
  # first render, or when the projection process is unreachable, fall back to the
  # loading view rather than crashing the LiveView.
  defp assign_initial_current_run_outcomes(socket, connected) do
    snapshot = if connected, do: read_current_run_outcomes_snapshot(), else: nil

    socket
    |> assign(:current_run_outcomes_source, nil)
    |> assign(:current_run_outcomes_pending, nil)
    |> assign(:current_run_outcomes_flush_scheduled?, false)
    |> apply_current_run_outcomes(snapshot)
  end

  defp read_current_run_outcomes_snapshot do
    CurrentRunOutcomeSnapshot.snapshot()
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  # Coalesce bursts of daemon updates: keep only the latest pending snapshot and
  # flush once per debounce window so high-frequency renders and screen-reader
  # announcements stay bounded.
  defp stash_current_run_outcomes(socket, snapshot) do
    socket = assign(socket, :current_run_outcomes_pending, snapshot)

    if socket.assigns.current_run_outcomes_flush_scheduled? do
      socket
    else
      schedule_current_run_outcomes_flush()
      assign(socket, :current_run_outcomes_flush_scheduled?, true)
    end
  end

  defp flush_current_run_outcomes(socket) do
    socket = assign(socket, :current_run_outcomes_flush_scheduled?, false)

    case socket.assigns.current_run_outcomes_pending do
      nil -> socket
      snapshot -> socket |> assign(:current_run_outcomes_pending, nil) |> apply_current_run_outcomes(snapshot)
    end
  end

  # Reconcile an incoming snapshot against the displayed source (last-known-good
  # retention lives in the presenter) and assign the presented, generation-pinned
  # view plus a single bounded announcement.
  defp apply_current_run_outcomes(socket, snapshot) do
    {source, retained?} = CurrentRunOutcomesPresenter.reconcile(socket.assigns.current_run_outcomes_source, snapshot)
    status_source = if retained?, do: snapshot, else: nil
    view = CurrentRunOutcomesPresenter.present(source, retained?, status_source)

    socket
    |> assign(:current_run_outcomes_source, source)
    |> assign(:current_run_outcomes, view)
    |> assign(:current_run_outcomes_announcement, CurrentRunOutcomesPresenter.announcement(view))
  end

  defp schedule_current_run_outcomes_flush do
    case Endpoint.config(:current_run_outcomes_flush_timer) do
      timer when is_function(timer, 3) -> timer.(self(), :flush_current_run_outcomes, @current_run_outcomes_flush_ms)
      _other -> Process.send_after(self(), :flush_current_run_outcomes, @current_run_outcomes_flush_ms)
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
    composer = agent_log_composer(socket.assigns.payload, row)

    socket
    |> replace_conversation_subscription(handle)
    |> assign(:conversation_handle, handle)
    |> assign(:conversation_identity, Map.get(row, :identity))
    |> assign(:conversation_row, row)
    |> assign(:conversation_origin_id, "units-conversation-#{token}")
    |> assign(:conversation_lifecycle, :active)
    |> assign(:conversation_snapshot, snapshot)
    |> assign(:conversation_log, log_for_drawer(composer))
    |> assign(:agent_log_modal, composer)
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
    |> assign(:conversation_log, nil)
    |> assign(:agent_log_modal, nil)
  end

  defp present_conversation(socket) do
    view =
      ConversationPresenter.present(
        socket.assigns.conversation_row,
        socket.assigns.conversation_snapshot,
        socket.assigns.conversation_lifecycle,
        socket.assigns.conversation_log
      )

    assign(socket, :conversation_drawer, view)
  end

  # The chat modal carries the running agent's workspace log and the writable
  # composer beneath the conversation. `agent_log_composer/2` builds the same
  # AgentLogModal payload (target key, writable target, parsed transcript) so the
  # existing composer handlers apply to the drawer; the drawer surfaces only the
  # parsed transcript, never the local path.
  defp agent_log_composer(payload, row) do
    case AgentLogModal.find_running_entry(payload, Map.get(row, :identity)) do
      %{} = entry -> AgentLogModal.build(entry, payload)
      _none -> nil
    end
  end

  defp log_for_drawer(%{messages: messages}) when is_list(messages), do: %{messages: messages}
  defp log_for_drawer(_composer), do: nil

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

  # --- Command history -------------------------------------------------------
  #
  # History is an ordered list of rows the operator has loaded, so "Load more"
  # appends one page to what is already on screen. Rows are always read back
  # from the retained store: a Command reaches history because the store says it
  # left the queue, never because a click hid a card.
  #
  # A stream would be the cheaper structure for an append-only table, but a row
  # is now an accordion: expanding one has to re-render that row, and a stream
  # item only re-renders when it is re-inserted — which would also move it to a
  # new position in the list.

  defp init_history_rows(socket) do
    socket
    |> assign(:history_rows, [])
    |> assign(:history_ids, MapSet.new())
    |> assign(:history_cursor, nil)
    |> assign(:history_total, nil)
    |> assign(:history_has_more, false)
    |> assign(:history_health, :ok)
    |> assign(:history_mounted?, false)
  end

  # The table only exists on the Commands routes. Leaving them unmounts the
  # stream container, so coming back has to re-read the first page: a stream
  # whose container was removed has nothing left on the server to re-render.
  # Patching inside the route keeps the container, and therefore the pages the
  # operator already loaded.
  defp load_history(socket, mode) do
    cond do
      Map.get(socket.assigns, :live_action) not in [:decisions, :decision] ->
        assign(socket, :history_mounted?, false)

      Map.get(socket.assigns, :history_mounted?) != true ->
        socket |> reset_history() |> assign(:history_mounted?, true)

      true ->
        do_load_history(socket, mode)
    end
  end

  defp do_load_history(socket, :first_page), do: do_load_history(socket, :head)

  defp do_load_history(socket, :next_page) do
    case history_page(socket.assigns.history_cursor) do
      {:ok, page} -> append_history(socket, page)
      :error -> assign(socket, :history_health, :unavailable)
    end
  end

  # A payload reload only reconciles the head of the list: newly resolved
  # Commands are inserted, already-streamed rows are left untouched, and the
  # operator's loaded pages are never collapsed back to ten.
  defp do_load_history(socket, :head) do
    case history_page(nil) do
      {:ok, page} -> merge_history_head(socket, page)
      :error -> assign(socket, :history_health, :unavailable)
    end
  end

  defp reset_history(socket) do
    case history_page(nil) do
      {:ok, page} -> reset_history_with(page, socket)
      :error -> assign(socket, :history_health, :unavailable)
    end
  end

  defp reset_history_with(page, socket) do
    socket
    |> assign(:history_rows, page.decisions)
    |> assign(:history_ids, MapSet.new(page.decisions, & &1.decision_id))
    |> assign(:history_cursor, get_in(page, [:pagination, :next_cursor]))
    |> assign(:history_total, get_in(page, [:pagination, :total]))
    |> assign(:history_has_more, not is_nil(get_in(page, [:pagination, :next_cursor])))
    |> assign(:history_health, history_health(page))
  end

  defp append_history(socket, page) do
    new_rows = Enum.reject(page.decisions, &MapSet.member?(socket.assigns.history_ids, &1.decision_id))

    socket
    |> append_history_rows(new_rows)
    |> assign(:history_cursor, get_in(page, [:pagination, :next_cursor]))
    |> assign(:history_total, get_in(page, [:pagination, :total]))
    |> assign(:history_has_more, not is_nil(get_in(page, [:pagination, :next_cursor])))
    |> assign(:history_health, history_health(page))
  end

  defp merge_history_head(socket, page) do
    if MapSet.size(socket.assigns.history_ids) == 0 do
      reset_history_with(page, socket)
    else
      {known_rows, new_rows} =
        Enum.split_with(page.decisions, &MapSet.member?(socket.assigns.history_ids, &1.decision_id))

      socket
      |> refresh_history_rows(known_rows)
      |> prepend_history_rows(new_rows)
      |> assign(:history_total, get_in(page, [:pagination, :total]))
      |> assign(:history_health, history_health(page))
    end
  end

  # Called after an operator action: the decision is re-read from the store and
  # only joins history if the store itself now reports a history status. A
  # failed write leaves the card exactly where it was.
  defp promote_history_row(socket, decision_id) do
    with true <- Map.get(socket.assigns, :live_action) in [:decisions, :decision],
         {:ok, %{decision: decision}} <- PayloadLoader.detail(decision_id),
         true <- decision.decision_status in @history_statuses do
      # The total stays whatever the store reported for the whole history set;
      # it is never incremented locally, so it cannot drift from the rows.
      #
      # A Command already in the table is refreshed where it sits. Only a
      # Command arriving in history for the first time joins at the head —
      # answering from inside an open row must not make that row jump out from
      # under the operator who is reading it.
      if MapSet.member?(socket.assigns.history_ids, decision_id) do
        refresh_history_rows(socket, [decision])
      else
        prepend_history_rows(socket, [decision])
      end
    else
      _other -> socket
    end
  end

  # A finished Command is read where it lives: expanded inside its own history
  # row. The inbox only ever hoists a Command the operator can still act on from
  # the queue, so a history selection is not promoted to the top of the page.
  #
  # The one exception is a Command that history has not loaded — a deep link
  # past the pages on screen. There is no row to expand, so the card is still
  # the only way to see it.
  defp inbox_selected_decision(selected, history_rows) do
    if history_expanded_id(selected, history_rows), do: nil, else: selected
  end

  defp history_expanded_id(%{decision_id: decision_id, decision_status: status}, history_rows)
       when status in @history_statuses do
    if Enum.any?(history_rows, &(&1.decision_id == decision_id)), do: decision_id
  end

  defp history_expanded_id(_selected, _history_rows), do: nil

  defp history_action_state(decision_actions, decision_id) when is_binary(decision_id),
    do: Map.get(decision_actions, decision_id, %{})

  defp history_action_state(_decision_actions, _decision_id), do: %{}

  # A row already on screen is replaced in place with the freshly read copy,
  # never skipped. A Command can be revised after it reached history, and a row
  # holding its original answer would contradict the panel that expands out of
  # it — showing fresh facts while open and stale ones the moment it closes.
  # Position is preserved: this is a refresh, not a re-ordering.
  defp refresh_history_rows(socket, []), do: socket

  defp refresh_history_rows(socket, rows) do
    fresh = Map.new(rows, &{&1.decision_id, &1})

    assign(socket, :history_rows, Enum.map(socket.assigns.history_rows, &Map.get(fresh, &1.decision_id, &1)))
  end

  defp append_history_rows(socket, rows) do
    socket
    |> assign(:history_rows, socket.assigns.history_rows ++ rows)
    |> track_history_ids(rows)
  end

  # Prepending re-reads a Command the operator just acted on, so any older copy
  # of the same row is dropped rather than left behind as a stale duplicate.
  defp prepend_history_rows(socket, rows) do
    ids = MapSet.new(rows, & &1.decision_id)
    kept = Enum.reject(socket.assigns.history_rows, &MapSet.member?(ids, &1.decision_id))

    socket
    |> assign(:history_rows, rows ++ kept)
    |> track_history_ids(rows)
  end

  defp track_history_ids(socket, rows) do
    assign(socket, :history_ids, Enum.reduce(rows, socket.assigns.history_ids, &MapSet.put(&2, &1.decision_id)))
  end

  defp history_page(cursor) do
    query =
      %{"lifecycle" => "history", "limit" => History.page_size()}
      |> then(&if(is_binary(cursor), do: Map.put(&1, "cursor", cursor), else: &1))

    case PayloadLoader.decisions(query) do
      {:ok, page} -> {:ok, page}
      {:error, _reason} -> :error
    end
  end

  defp history_health(%{health: %{status: :unavailable}}), do: :unavailable
  defp history_health(%{health: %{status: :partial}}), do: :degraded
  defp history_health(_page), do: :ok

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

  # The inbox lists what the operator still owns. Answered, acknowledged,
  # expired and deferred Commands have all left it, and are read back from the
  # history table instead.
  defp put_filter_query(query, :open), do: Map.put(query, "lifecycle", "awaiting")

  defp put_filter_query(query, :blocking), do: query |> Map.put("lifecycle", "awaiting") |> Map.put("blocking", true)
  defp put_filter_query(query, :resolved), do: Map.put(query, "lifecycle", "history")
  defp put_filter_query(query, :all), do: Map.put(query, "lifecycle", "awaiting")
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
  defp schedule_github_quota_tick, do: Process.send_after(self(), :github_quota_tick, @github_quota_tick_ms)
  defp schedule_elevenlabs_quota_tick, do: Process.send_after(self(), :elevenlabs_quota_tick, @elevenlabs_quota_tick_ms)

  defp github_quota_snapshot, do: GitHubQuota.snapshot()

  defp elevenlabs_quota_snapshot, do: ElevenLabsQuota.snapshot()

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
