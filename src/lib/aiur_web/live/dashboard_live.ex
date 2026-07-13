defmodule AiurWeb.DashboardLive do
  @moduledoc """
  Phoenix LiveView shell for the Aiur Executor Control Center.
  """

  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias Aiur.{AgentChat, DecisionPubSub}
  alias AiurWeb.{ControlCenterPresenter, Endpoint, ObservabilityPubSub}

  alias AiurWeb.OperatorControlCenter.{
    AgentLogModal,
    DecisionEvents,
    DecisionInbox,
    DecisionPath,
    FleetFilters,
    FleetTable,
    History,
    Overview,
    PayloadLoader,
    RecentOutcomes
  }

  @runtime_tick_ms 1_000
  @decision_filters [:all, :open, :blocking, :undelivered, :supervisor, :resolved, :superseded]
  @decision_events DecisionEvents.events()

  @impl true
  def mount(params, _session, socket) do
    connected = connected?(socket)

    if connected do
      :ok = ObservabilityPubSub.subscribe()
      :ok = DecisionPubSub.subscribe()
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
      |> assign(:fleet_filters, FleetFilters.default())
      |> assign_selected_decision(params["decision_id"])
      |> PayloadLoader.mark_loaded()

    if connected, do: schedule_runtime_tick()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:decision_filter, normalize_filter(params["filter"]))
     |> assign_selected_decision(params["decision_id"])}
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

  @impl true
  def handle_info(:reload_payload, socket) do
    {:noreply, socket |> reload_payload(:cached) |> PayloadLoader.mark_loaded()}
  end

  @impl true
  def handle_event("filter-decisions", %{"filter" => filter}, socket) do
    filter = normalize_filter(filter)
    {:noreply, push_patch(socket, to: decision_path(socket.assigns.selected_decision_id, filter))}
  end

  def handle_event("filter-decisions", _params, socket), do: {:noreply, socket}

  def handle_event("toggle-fleet-filter", %{"filter" => filter}, socket) do
    {:noreply, update(socket, :fleet_filters, &FleetFilters.toggle(&1, filter))}
  end

  def handle_event("toggle-fleet-filter", _params, socket), do: {:noreply, socket}

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
    ~H"""
    <section class="dashboard-shell">
      <Overview.topbar now={@now} tracker_kind={tracker_kind()} agent_kind={agent_kind()} />
      <Overview.readonly_banner writable={@writable} />
      <Overview.decisions_banner decisions={@payload.decisions} />
      <Overview.tabs
        live_action={@live_action || :index}
        decision_count={length(@payload.decisions)}
        fleet_count={fleet_count(@payload.fleet)}
      />
      <Overview.error error={@payload.fleet[:error]} />

      <div :if={@live_action in [:decisions, :decision]} class="control-panel">
        <div :if={@live_action == :decision and is_nil(@selected_decision)} class="error-card" role="alert">
          <h2>Decision not found</h2>
          <p>No current decision matches <span class="mono">{@selected_decision_id}</span>.</p>
        </div>
        <DecisionInbox.decision_inbox
          decisions={@payload.decisions}
          selected_decision_id={@selected_decision_id}
          filter={@decision_filter}
          now={@now}
          history={@payload.history}
          action_states={@decision_actions}
          writable={@writable}
          provider_health={@payload.provider_health.decisions}
        />
      </div>

      <div :if={@live_action not in [:decisions, :decision]} class="control-panel">
        <FleetTable.fleet_table
          fleet={@payload.fleet}
          decisions={@payload.decisions}
          now={@now}
          filters={@fleet_filters}
        />
      </div>

      <section :if={@live_action == :index} class="section-card recent-card" aria-labelledby="recent-title">
        <header class="section-header">
          <div>
            <p class="section-eyebrow">Durable outcomes</p>
            <h2 id="recent-title">Recent</h2>
            <p>Repository merges and recorded decision actions from durable projections.</p>
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
    </section>
    """
  end

  defp reload_payload(socket, mode) do
    payload = PayloadLoader.load(mode)

    socket
    |> assign(:payload, payload)
    |> assign(:now, DateTime.utc_now())
    |> assign(:agent_log_modal, AgentLogModal.refresh(socket.assigns.agent_log_modal, payload))
    |> assign_selected_decision(socket.assigns.selected_decision_id)
  end

  defp reload_after_action(socket) do
    socket
    |> reload_payload(:fresh)
    |> PayloadLoader.mark_loaded()
  end

  defp assign_selected_decision(socket, decision_id) do
    selected =
      case ControlCenterPresenter.find_decision(socket.assigns.payload, decision_id) do
        {:ok, decision} -> decision
        :error -> nil
      end

    socket |> assign(:selected_decision_id, decision_id) |> assign(:selected_decision, selected)
  end

  defp normalize_filter(filter) when is_atom(filter) and filter in @decision_filters, do: filter

  defp normalize_filter(filter) when is_binary(filter) do
    Enum.find(@decision_filters, :all, &(Atom.to_string(&1) == filter))
  end

  defp normalize_filter(_filter), do: :all
  defp dashboard_writable?, do: Endpoint.config(:dashboard_writable) == true

  defp decision_path(nil, filter), do: DecisionPath.inbox(filter)
  defp decision_path(decision_id, filter), do: DecisionPath.detail(decision_id, filter)

  defp handle_writable_event(socket, fun) when is_function(fun, 0) do
    if dashboard_writable?() do
      fun.()
    else
      {:noreply, assign(socket, :writable, false)}
    end
  end

  defp tracker_kind, do: to_string(Aiur.Config.tracker_kind())
  defp agent_kind, do: to_string(Aiur.Config.agent_kind())

  defp fleet_count(fleet) do
    counts = Map.get(fleet, :counts, %{})
    Map.get(counts, :running, 0) + Map.get(counts, :retrying, 0) + Map.get(counts, :idle, 0)
  end

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
