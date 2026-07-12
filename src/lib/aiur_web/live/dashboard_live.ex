defmodule AiurWeb.DashboardLive do
  @moduledoc """
  Phoenix LiveView shell for the Aiur Operator Control Center.
  """

  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias Aiur.{AgentChat, DecisionPubSub}
  alias AiurWeb.{ControlCenterPresenter, Endpoint, ObservabilityPubSub}
  alias AiurWeb.OperatorControlCenter.{AgentLogModal, DecisionInbox, FleetTable, History, Overview, RecentOutcomes}

  @runtime_tick_ms 1_000
  @payload_reload_debounce_ms 50
  @decision_filters [:all, :open, :blocking, :answered]

  @impl true
  def mount(params, _session, socket) do
    payload = load_payload()

    socket =
      socket
      |> assign(:payload, payload)
      |> assign(:now, DateTime.utc_now())
      |> assign(:agent_log_modal, nil)
      |> assign(:drafts, %{})
      |> assign(:chat_errors, %{})
      |> assign(:payload_reload_scheduled?, false)
      |> assign(:writable, dashboard_writable?())
      |> assign(:decision_filter, :all)
      |> assign_selected_decision(params["decision_id"])

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      :ok = DecisionPubSub.subscribe()
      schedule_runtime_tick()
    end

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
    {:noreply, schedule_payload_reload(socket)}
  end

  @impl true
  def handle_info({:decision_changed, _decision_id, _version}, socket) do
    {:noreply, schedule_payload_reload(socket)}
  end

  @impl true
  def handle_info(:reload_payload, socket) do
    {:noreply,
     socket
     |> reload_payload()
     |> assign(:payload_reload_scheduled?, false)}
  end

  @impl true
  def handle_event("filter-decisions", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, :decision_filter, normalize_filter(filter))}
  end

  def handle_event("show-agent-log", %{"issue" => issue_identifier}, socket) do
    entry = AgentLogModal.find_running_entry(socket.assigns.payload, issue_identifier)
    {:noreply, assign(socket, :agent_log_modal, AgentLogModal.build(entry))}
  end

  def handle_event("close-agent-log", _params, socket) do
    {:noreply, assign(socket, :agent_log_modal, nil)}
  end

  def handle_event("composer-change", %{"message" => message}, %{assigns: %{writable: true, agent_log_modal: modal}} = socket)
      when is_map(modal) do
    identifier = modal.issue_identifier

    {:noreply,
     socket
     |> assign(:drafts, Map.put(socket.assigns.drafts, identifier, message))
     |> assign(:chat_errors, Map.delete(socket.assigns.chat_errors, identifier))}
  end

  def handle_event("composer-change", _params, socket), do: {:noreply, socket}

  def handle_event("send-operator-message", %{"message" => message}, %{assigns: %{writable: true, agent_log_modal: modal}} = socket)
      when is_map(modal) do
    identifier = modal.issue_identifier

    case String.trim(message) do
      "" ->
        {:noreply, socket}

      text ->
        case AgentChat.send(identifier, text) do
          {:ok, _request_id} -> {:noreply, clear_chat_state(socket, identifier)}
          {:error, reason} -> {:noreply, put_chat_error(socket, identifier, reason)}
        end
    end
  end

  def handle_event("send-operator-message", _params, socket), do: {:noreply, socket}

  def handle_event("pause-agent", _params, %{assigns: %{writable: true, agent_log_modal: modal}} = socket) when is_map(modal) do
    identifier = modal.issue_identifier

    case AgentChat.pause(identifier) do
      {:ok, _request_id} -> {:noreply, assign(socket, :chat_errors, Map.delete(socket.assigns.chat_errors, identifier))}
      {:error, reason} -> {:noreply, put_chat_error(socket, identifier, reason)}
    end
  end

  def handle_event("pause-agent", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <Overview.topbar now={@now} tracker_kind={tracker_kind()} agent_kind={agent_kind()} />
      <Overview.readonly_banner writable={@writable} />
      <Overview.decisions_banner decisions={@payload.decisions} />
      <Overview.overview overview={@payload.overview} />
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
          writable={@writable}
          provider_health={@payload.provider_health.decisions}
        />
      </div>

      <div :if={@live_action not in [:decisions, :decision]} class="control-panel">
        <FleetTable.fleet_table fleet={@payload.fleet} decisions={@payload.decisions} now={@now} />
      </div>

      <section class="section-card recent-card" aria-labelledby="recent-title">
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

      <AgentLogModal.agent_log_modal modal={@agent_log_modal} writable={@writable} drafts={@drafts} errors={@chat_errors} />
    </section>
    """
  end

  defp reload_payload(socket) do
    payload = load_payload()

    socket
    |> assign(:payload, payload)
    |> assign(:now, DateTime.utc_now())
    |> assign(:agent_log_modal, AgentLogModal.refresh(socket.assigns.agent_log_modal, payload))
    |> assign_selected_decision(socket.assigns.selected_decision_id)
  end

  defp schedule_payload_reload(%{assigns: %{payload_reload_scheduled?: true}} = socket), do: socket

  defp schedule_payload_reload(socket) do
    Process.send_after(self(), :reload_payload, @payload_reload_debounce_ms)
    assign(socket, :payload_reload_scheduled?, true)
  end

  defp load_payload do
    ControlCenterPresenter.state_payload(orchestrator(), snapshot_timeout_ms(),
      decision_store: Endpoint.config(:decision_store) || Aiur.DecisionStore,
      recent_merge_store: Endpoint.config(:recent_merge_store) || Aiur.RecentMergeStore
    )
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
  defp orchestrator, do: Endpoint.config(:orchestrator) || Aiur.Orchestrator
  defp snapshot_timeout_ms, do: Endpoint.config(:snapshot_timeout_ms) || 15_000
  defp dashboard_writable?, do: Endpoint.config(:dashboard_writable) == true

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
end
