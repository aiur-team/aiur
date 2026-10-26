defmodule AiurWeb.DashboardLive do
  @moduledoc """
  Phoenix LiveView shell for the Aiur Operator Control Center.
  """
  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias Aiur.BuildOrder.TicketDetail.State, as: TicketDetailState
  alias Aiur.BuildOrder.TicketHistory.Snapshot, as: TicketHistorySnapshot
  alias Aiur.ProviderMeterRefresh
  alias AiurWeb.DashboardLive.CommandHistory
  alias AiurWeb.DashboardLive.Commands
  alias AiurWeb.DashboardLive.Controls
  alias AiurWeb.DashboardLive.Conversation
  alias AiurWeb.DashboardLive.Page
  alias AiurWeb.DashboardLive.ProviderMeters
  alias AiurWeb.DashboardLive.RepositoryLeaderBanner
  alias AiurWeb.DashboardLive.Session
  alias AiurWeb.DashboardLive.Summaries
  alias AiurWeb.DashboardLive.TicketContext
  alias AiurWeb.DashboardLive.UnitsPanel
  alias AiurWeb.DashboardLive.Usage
  alias AiurWeb.DashboardLive.Voice
  alias AiurWeb.FinancialData
  alias AiurWeb.OperatorControlCenter.AgentLogModal
  alias AiurWeb.OperatorControlCenter.DecisionEvents
  alias AiurWeb.OperatorControlCenter.NavState
  alias AiurWeb.OperatorControlCenter.PayloadLoader
  alias AiurWeb.OperatorControlCenter.TicketsPresenter
  alias AiurWeb.OperatorControlCenter.UnitsPresenter
  alias AiurWeb.OperatorControlCenter.UnitsURL

  @max_ticket_query_length 128
  @decision_events DecisionEvents.events()

  @impl true
  def mount(_params, _session, socket), do: Session.mount(socket)

  @impl true
  def handle_params(params, uri, socket), do: Session.handle_params(params, uri, socket)

  @impl true
  def handle_info(:runtime_tick, socket) do
    Session.schedule_runtime_tick()
    {:noreply, RepositoryLeaderBanner.refresh(socket)}
  end

  def handle_info(:instance_roster_tick, socket), do: {:noreply, Session.refresh_instance_roster(socket)}

  def handle_info(:github_quota_tick, socket) do
    Session.schedule_github_quota_tick()
    {:noreply, socket |> assign(:github_quota, Session.github_quota_snapshot()) |> PayloadLoader.schedule()}
  end

  def handle_info(:elevenlabs_quota_tick, socket) do
    Session.schedule_elevenlabs_quota_tick()
    {:noreply, Voice.assign_voice(socket)}
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
    {:noreply, Summaries.stash_run_summary(socket, snapshot)}
  end

  def handle_info(:flush_run_summary, socket) do
    {:noreply, Summaries.flush_run_summary(socket)}
  end

  def handle_info({FinancialData, :updated, _identity} = message, socket) do
    socket =
      socket
      |> Usage.stash_usage_summary(message)
      |> ProviderMeters.schedule_provider_meters_reload(message)

    {:noreply, socket}
  end

  def handle_info(:flush_usage_summary, socket) do
    {:noreply, Usage.flush_usage_summary(socket)}
  end

  def handle_info(:flush_provider_meters, socket) do
    {:noreply, ProviderMeters.flush_provider_meters(socket)}
  end

  def handle_info({:current_run_outcome_snapshot_changed, snapshot}, socket) do
    {:noreply, Summaries.stash_current_run_outcomes(socket, snapshot)}
  end

  def handle_info(:flush_current_run_outcomes, socket) do
    {:noreply, Summaries.flush_current_run_outcomes(socket)}
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
    {:noreply, TicketContext.maybe_update_ticket_context(socket, :detail, detail)}
  end

  def handle_info({:ticket_history_updated, %TicketHistorySnapshot{} = history}, socket) do
    {:noreply, TicketContext.maybe_update_ticket_context(socket, :history, history)}
  end

  def handle_info({:ticket_history_evicted, identity, _generation}, socket) do
    {:noreply, TicketContext.maybe_reset_ticket_context(socket, :history, identity)}
  end

  def handle_info({:ticket_detail_coordinator_reset, _epoch}, socket) do
    {:noreply, TicketContext.reset_selected_ticket_context(socket, :detail)}
  end

  def handle_info({:ticket_history_reset, _epoch}, socket) do
    {:noreply, TicketContext.reset_selected_ticket_context(socket, :history)}
  end

  def handle_info({:live_conversation_changed, snapshot}, socket) do
    {:noreply, Conversation.maybe_update_conversation(socket, snapshot)}
  end

  def handle_info({:live_conversation_restarted, _epoch, _now}, socket) do
    {:noreply, Conversation.supersede_conversation(socket)}
  end

  @impl true
  def handle_info(:reload_payload, socket) do
    mode = Map.get(socket.assigns, :payload_reload_mode, :cached)
    {:noreply, socket |> Commands.reload_payload(mode) |> PayloadLoader.mark_loaded()}
  end

  def handle_info({:control_lifecycle, payload}, socket) when is_map(payload) do
    {:noreply, Controls.apply_control_lifecycle(socket, payload)}
  end

  # A unit's agent topic carries transcript, alert, turn, and aiur-turn traffic
  # this view subscribes to but does not consume. Ignore it rather than crashing
  # on any message this view does not own.
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle-nav", _params, socket), do: {:noreply, NavState.toggle(socket)}

  @impl true
  def handle_event("restore-nav", %{"collapsed" => collapsed}, socket),
    do: {:noreply, NavState.restore(socket, collapsed)}

  @impl true
  def handle_event("filter-decisions", %{"filter" => filter}, socket) do
    filter = Commands.normalize_filter(filter)
    {:noreply, push_patch(socket, to: Commands.decision_path(socket.assigns.selected_decision_id, filter, %{}))}
  end

  def handle_event("filter-decisions", _params, socket), do: {:noreply, socket}

  def handle_event("search-commands", %{"search" => search}, socket) when is_binary(search), do: Commands.on_search_commands(search, socket)

  def handle_event("search-commands", _params, socket), do: {:noreply, socket}

  def handle_event("table-sort-changed", %{"sort" => sort}, socket),
    do: {:noreply, assign(socket, :table_sort, UnitsPanel.normalize_table_sort(sort))}

  def handle_event("table-sort-changed", _params, socket), do: {:noreply, socket}

  def handle_event("usage-drill-down", %{"dimension" => dimension}, socket) do
    {:noreply, Usage.open_usage_drill(socket, dimension)}
  end

  def handle_event("usage-drill-more", %{"dimension" => dimension, "cursor" => cursor}, socket) do
    {:noreply, Usage.page_usage_drill(socket, dimension, cursor)}
  end

  def handle_event("usage-drill-close", _params, socket) do
    {:noreply, assign(socket, usage_summary_drill: nil, usage_summary_drill_trigger: nil)}
  end

  def handle_event("select-units-scope", %{"scope" => scope}, socket) do
    selection = UnitsPresenter.select_scope(socket.assigns.units_selection, scope)
    {:noreply, push_patch(socket, to: UnitsPanel.units_path(socket, selection))}
  end

  def handle_event("select-units-scope", _params, socket), do: {:noreply, socket}

  def handle_event("toggle-units-condition", %{"condition" => condition}, socket) do
    selection = UnitsPresenter.toggle_condition(socket.assigns.units_selection, condition)
    {:noreply, push_patch(socket, to: UnitsPanel.units_path(socket, selection))}
  end

  def handle_event("toggle-units-condition", _params, socket), do: {:noreply, socket}

  def handle_event("select-all-units-filters", _params, socket) do
    {:noreply, push_patch(socket, to: UnitsPanel.units_path(socket, UnitsPresenter.select_all_filters()))}
  end

  def handle_event("select-no-units-filters", _params, socket) do
    {:noreply, push_patch(socket, to: UnitsPanel.units_path(socket, UnitsPresenter.select_no_filters()))}
  end

  def handle_event("reset-units-filters", _params, socket) do
    {:noreply, push_patch(socket, to: UnitsPanel.units_path(socket, UnitsURL.zero_result_reset()))}
  end

  def handle_event("inspect-unit", %{"unit" => token}, socket) when is_binary(token), do: TicketContext.on_inspect_unit(token, socket)

  def handle_event("inspect-unit", _params, socket), do: {:noreply, socket}

  def handle_event("request-unit-control", %{"unit" => token, "action" => action}, socket)
      when is_binary(token) and action in ["pause", "resume"] do
    handle_writable_event(socket, fn ->
      {:noreply, Controls.request_unit_control(socket, token, String.to_existing_atom(action))}
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
    {:noreply, socket |> assign(:tickets_query, String.slice(query, 0, @max_ticket_query_length)) |> UnitsPanel.assign_tickets_panel_view()}
  end

  def handle_event("search-tickets", _params, socket), do: {:noreply, socket}

  def handle_event("clear-ticket-search", _params, socket) do
    {:noreply, socket |> assign(:tickets_query, "") |> UnitsPanel.assign_tickets_panel_view()}
  end

  def handle_event("open-add-agent", %{"ticket" => token}, socket) when is_binary(token),
    do: if(socket.assigns.writable and Session.dashboard_writable?(), do: UnitsPanel.on_open_add_agent(token, socket), else: {:noreply, socket})

  def handle_event("open-add-agent", _params, socket), do: {:noreply, socket}

  def handle_event("close-add-agent", _params, socket),
    do: {:noreply, assign(socket, :add_agent_modal, nil)}

  def handle_event("change-add-agent", _params, %{assigns: %{add_agent_pending: %{}}} = socket),
    do: {:noreply, socket}

  def handle_event(
        "change-add-agent",
        params,
        %{assigns: %{add_agent_modal: %{} = modal}} = socket
      ) do
    {:noreply, assign(socket, :add_agent_modal, UnitsPanel.change_add_agent(modal, params))}
  end

  def handle_event("change-add-agent", _params, socket), do: {:noreply, socket}

  def handle_event("confirm-add-agent", _params, %{assigns: %{add_agent_pending: %{}}} = socket),
    do: {:noreply, socket}

  def handle_event(
        "confirm-add-agent",
        params,
        %{assigns: %{add_agent_modal: %{} = modal}} = socket
      ),
      do: handle_writable_event(socket, fn -> UnitsPanel.on_confirm_add_agent(params, modal, socket) end)

  def handle_event("confirm-add-agent", _params, socket), do: {:noreply, socket}

  def handle_event("close-ticket-context", _params, socket), do: TicketContext.on_close_ticket_context(socket)

  def handle_event("read-conversation", %{"unit" => token}, socket) when is_binary(token), do: Conversation.on_read_conversation(token, socket)

  def handle_event("read-conversation", _params, socket), do: {:noreply, socket}

  def handle_event("close-conversation", _params, socket), do: Conversation.on_close_conversation(socket)

  def handle_event(event, params, socket) when event in @decision_events do
    decision_id = params["decision_id"] || params["decision-id"]
    reload = &(&1 |> Commands.reload_after_action() |> CommandHistory.promote_history_row(decision_id))

    handle_writable_event(socket, fn ->
      {:noreply, DecisionEvents.handle(event, params, socket, reload)}
    end)
  end

  def handle_event("load-more-history", _params, socket) do
    {:noreply, CommandHistory.load_history(socket, :next_page)}
  end

  def handle_event("show-agent-log", %{"unit" => token}, socket) when is_binary(token), do: Conversation.on_show_agent_log(token, socket)

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
      when is_map(modal), do: handle_writable_event(socket, fn -> Conversation.on_composer_change(message, modal, socket) end)

  def handle_event("composer-change", _params, socket), do: {:noreply, socket}

  def handle_event(
        "send-operator-message",
        %{"message" => message},
        %{assigns: %{writable: true, agent_log_modal: modal}} = socket
      )
      when is_map(modal), do: handle_writable_event(socket, fn -> Conversation.on_send_operator_message(message, modal, socket) end)

  def handle_event("send-operator-message", _params, socket), do: {:noreply, socket}

  def handle_event(
        "pause-agent",
        _params,
        %{assigns: %{writable: true, agent_log_modal: modal}} = socket
      )
      when is_map(modal) do
    handle_writable_event(socket, fn -> Conversation.pause_agent_action(socket, modal) end)
  end

  def handle_event("pause-agent", _params, socket), do: {:noreply, socket}

  def handle_event("capacity-input-change", %{"max" => value}, socket) when is_binary(value) do
    {:noreply, assign(socket, :capacity_input, value)}
  end

  def handle_event("capacity-input-change", _params, socket), do: {:noreply, socket}

  def handle_event("capacity-decrement", _params, socket) do
    handle_writable_event(socket, fn -> {:noreply, Controls.adjust_capacity(socket, -1)} end)
  end

  def handle_event("capacity-increment", _params, socket) do
    handle_writable_event(socket, fn -> {:noreply, Controls.adjust_capacity(socket, 1)} end)
  end

  def handle_event("capacity-set", %{"max" => value}, socket) when is_binary(value) do
    handle_writable_event(socket, fn -> {:noreply, Controls.set_capacity(socket, value)} end)
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
    handle_writable_event(socket, fn -> {:noreply, Controls.toggle_global_pause(socket)} end)
  end

  @impl true
  def handle_async(:add_agent_submission, {:ok, result}, socket),
    do: UnitsPanel.finish_add_agent(socket, result)

  def handle_async(:add_agent_submission, {:exit, reason}, socket) do
    UnitsPanel.finish_add_agent(socket, %{
      added: [],
      removed: [],
      error: {:submission_exit, reason},
      authorization: :unknown
    })
  end

  @impl true
  def render(assigns), do: Page.page(assigns)

  defp handle_writable_event(socket, fun) when is_function(fun, 0) do
    if Session.dashboard_writable?() do
      fun.()
    else
      {:noreply, assign(socket, :writable, false)}
    end
  end
end
