defmodule AiurWeb.DashboardLive do
  @moduledoc """
  Phoenix LiveView shell for the Aiur Operator Control Center.
  """
  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias AiurWeb.DashboardLive.CommandHistory
  alias AiurWeb.DashboardLive.Commands
  alias AiurWeb.DashboardLive.Controls
  alias AiurWeb.DashboardLive.Page
  alias AiurWeb.DashboardLive.RepositoryLeaderBanner
  alias AiurWeb.DashboardLive.Session
  alias AiurWeb.DashboardLive.UnitsPanel
  alias AiurWeb.DashboardLive.Voice
  alias AiurWeb.OperatorControlCenter.DecisionEvents
  alias AiurWeb.OperatorControlCenter.NavState
  alias AiurWeb.OperatorControlCenter.PayloadLoader

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

  def handle_info(:github_quota_tick, socket) do
    Session.schedule_github_quota_tick()
    {:noreply, PayloadLoader.schedule(socket)}
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

  def handle_info({:current_run_membership_health_changed, payload}, socket) do
    {:noreply, PayloadLoader.schedule(socket, {:event, {:membership_health, Map.get(payload, :generation)}})}
  end

  def handle_info({:ticket_activity_changed, payload}, socket) do
    {:noreply, PayloadLoader.schedule(socket, {:event, {:activity, Map.get(payload, :generation)}})}
  end

  def handle_info({:open_tickets_updated, change}, socket) do
    {:noreply, PayloadLoader.schedule(socket, {:event, {:open_tickets, Map.get(change, :generation)}})}
  end

  @impl true
  def handle_info(:reload_payload, socket) do
    mode = Map.get(socket.assigns, :payload_reload_mode, :cached)
    {:noreply, socket |> Commands.reload_payload(mode) |> PayloadLoader.mark_loaded()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true

  def handle_event("open-voice-conversation", params, socket), do: {:noreply, AiurWeb.VoiceConversationEvents.open(socket, params)}

  def handle_event("close-voice-conversation", _params, socket), do: {:noreply, AiurWeb.VoiceConversationEvents.close(socket)}

  def handle_event("toggle-nav", _params, socket), do: {:noreply, NavState.toggle(socket)}

  @impl true
  def handle_event("restore-nav", %{"collapsed" => collapsed}, socket),
    do: {:noreply, NavState.restore(socket, collapsed)}

  @impl true
  def handle_event("filter-decisions", %{"filter" => filter}, socket) do
    filter = Commands.normalize_filter(filter)

    {:noreply,
     push_patch(socket,
       to:
         Commands.decision_path(
           socket.assigns.selected_decision_id,
           filter,
           Map.take(socket.assigns.decision_query, [:requester])
         )
     )}
  end

  def handle_event("filter-decisions", _params, socket), do: {:noreply, socket}

  def handle_event("search-commands", %{"search" => search}, socket) when is_binary(search),
    do: Commands.on_search_commands(search, socket)

  def handle_event("search-commands", _params, socket), do: {:noreply, socket}

  def handle_event("table-sort-changed", %{"sort" => sort}, socket),
    do: {:noreply, assign(socket, :table_sort, UnitsPanel.normalize_table_sort(sort))}

  def handle_event("table-sort-changed", _params, socket), do: {:noreply, socket}

  def handle_event(event, params, socket) when event in @decision_events do
    decision_id = params["decision_id"] || params["decision-id"]

    reload =
      &(&1 |> Commands.reload_after_action() |> CommandHistory.promote_history_row(decision_id))

    handle_writable_event(socket, fn ->
      {:noreply, DecisionEvents.handle(event, params, socket, reload)}
    end)
  end

  def handle_event("load-more-history", _params, socket) do
    {:noreply, CommandHistory.load_history(socket, :next_page)}
  end

  def handle_event("toggle-global-pause", _params, socket) do
    handle_writable_event(socket, fn -> {:noreply, Controls.toggle_global_pause(socket)} end)
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
