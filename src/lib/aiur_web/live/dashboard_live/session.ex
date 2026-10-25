defmodule AiurWeb.DashboardLive.Session do
  @moduledoc false

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  alias AiurWeb.DashboardLive.CommandHistory
  alias AiurWeb.DashboardLive.Commands
  alias AiurWeb.DashboardLive.Controls
  alias AiurWeb.DashboardLive.Conversation
  alias AiurWeb.DashboardLive.GitHubQuotaSnapshot
  alias AiurWeb.DashboardLive.ProviderMeters
  alias AiurWeb.DashboardLive.Summaries
  alias AiurWeb.DashboardLive.TicketContext
  alias AiurWeb.DashboardLive.UnitsPanel
  alias AiurWeb.DashboardLive.Usage
  alias AiurWeb.DashboardLive.Voice
  alias AiurWeb.EndpointConfig
  alias AiurWeb.OperatorControlCenter.NavState
  alias AiurWeb.OperatorControlCenter.PayloadLoader
  alias AiurWeb.OperatorControlCenter.RouteRegistry
  alias AiurWeb.OperatorControlCenter.TicketsPresenter
  alias AiurWeb.OperatorControlCenter.UnitsURL

  @runtime_tick_ms 1_000
  # Also refreshes the otherwise event-driven payload.
  @github_quota_tick_ms 15_000
  # Whole-account voice credit changes more slowly than the GitHub budget.
  @elevenlabs_quota_tick_ms 60_000

  @doc false
  @spec mount(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(socket) do
    socket = NavState.assign_nav(socket)
    connected = connected?(socket)

    socket = AiurWeb.RefreshSubscriptions.dashboard(socket)
    if connected, do: TicketContext.subscribe_ticket_context_resets()

    payload = PayloadLoader.load(if connected, do: :join, else: :cached)

    socket =
      socket
      |> assign(:payload, payload)
      |> assign(:now, DateTime.utc_now())
      |> assign(:time_zone, browser_time_zone(socket))
      |> assign(:github_quota, github_quota_snapshot())
      |> Voice.assign_voice()
      |> assign(:agent_log_modal, nil)
      |> assign(:drafts, %{})
      |> assign(:pending_message_ids, %{})
      |> assign(:chat_errors, %{})
      |> assign(:decision_actions, %{})
      |> assign(:global_pause_error, nil)
      |> assign(:payload_reload_scheduled?, false)
      |> assign(:payload_reload_mode, :cached)
      |> assign(%{writable: dashboard_writable?(), live_connected: connected})
      |> assign(:decision_filter, :all)
      |> assign(:decision_page, Commands.empty_decision_page())
      |> assign(:decision_query, %{})
      |> CommandHistory.init_history_rows()
      |> assign(:units_selection, UnitsURL.default_selection())
      |> assign(:unit_controls, %{})
      |> assign(:unit_control_subscriptions, MapSet.new())
      |> assign(:tickets_visible, TicketsPresenter.initial_reveal())
      |> UnitsPanel.assign_units_view()
      |> Controls.sync_unit_control_subscriptions(connected)
      |> assign(:capacity_input, "")
      |> assign(:capacity_feedback, nil)
      |> Summaries.assign_initial_run_summary(connected)
      |> ProviderMeters.assign_initial_provider_meters(connected)
      |> Summaries.assign_initial_current_run_outcomes(connected)
      |> Usage.assign_initial_usage_summary(connected)
      |> assign(:ticket_detail, nil)
      |> assign(:tickets_query, "")
      |> assign(:add_agent_modal, nil)
      |> assign(:add_agent_pending, nil)
      |> assign(:add_agent_notice, nil)
      |> assign(:ticket_context, nil)
      |> assign(:ticket_context_detail, nil)
      |> assign(:ticket_context_history, nil)
      |> assign(:ticket_context_identity, nil)
      |> assign(:ticket_context_row, nil)
      |> assign(:ticket_context_subscriptions, MapSet.new())
      |> assign(:conversation_drawer, nil)
      |> assign(:conversation_from_route?, false)
      |> assign(:conversation_notice, nil)
      |> assign(:conversation_handle, nil)
      |> assign(:conversation_identity, nil)
      |> assign(:conversation_row, nil)
      |> assign(:conversation_origin_id, nil)
      |> assign(:conversation_lifecycle, :active)
      |> assign(:conversation_snapshot, nil)
      |> assign(:conversation_usage_snapshot, nil)
      |> assign(:conversation_usage_error, nil)
      |> assign(:selected_decision_id, nil)
      |> assign(:selected_decision, nil)
      |> assign(:selected_decision_status, :none)
      |> assign(:selected_decision_health, nil)
      |> assign(:current_route, RouteRegistry.current_route(Map.get(socket.assigns, :live_action)))
      |> PayloadLoader.mark_joined(connected)

    if connected do
      schedule_runtime_tick()
      schedule_github_quota_tick()
      schedule_elevenlabs_quota_tick()
    end

    {:ok, socket}
  end

  @doc false
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_params(params, uri, socket) do
    filter = Commands.normalize_filter(params["filter"])
    conversation_route? = String.starts_with?(URI.parse(uri).path || "", "/chat/")

    {:noreply,
     socket
     |> assign(%{units_base_path: if(conversation_route?, do: "/units", else: URI.parse(uri).path), decision_filter: filter})
     |> assign(:table_sort, UnitsPanel.normalize_table_sort(params["sort"]))
     |> assign(:current_route, RouteRegistry.current_route(Map.get(socket.assigns, :live_action)))
     |> assign(:conversation_from_route?, conversation_route?)
     |> UnitsPanel.assign_units_selection(params)
     |> Commands.assign_decision_page(filter, params)
     |> CommandHistory.load_history(:first_page)
     |> Commands.assign_selected_decision(params["decision_id"])
     |> Conversation.maybe_open_conversation_route(if(conversation_route?, do: params, else: %{}))
     |> UnitsPanel.maybe_canonicalize_units_url(params)}
  end

  @doc false
  @spec dashboard_writable?() :: boolean()
  def dashboard_writable?, do: EndpointConfig.get(:dashboard_writable) == true

  # The browser reports its IANA timezone through the LiveSocket connect params.
  # Fall back to UTC when it is missing (initial render, fixture, or a browser
  # that does not expose Intl).
  defp browser_time_zone(socket) do
    case Phoenix.LiveView.get_connect_params(socket) do
      %{"time_zone" => zone} when is_binary(zone) and zone != "" -> zone
      _ -> "Etc/UTC"
    end
  end

  @doc false
  @spec schedule_runtime_tick() :: term()
  def schedule_runtime_tick, do: Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  @doc false
  @spec schedule_github_quota_tick() :: term()
  def schedule_github_quota_tick, do: Process.send_after(self(), :github_quota_tick, @github_quota_tick_ms)
  @doc false
  @spec schedule_elevenlabs_quota_tick() :: term()
  def schedule_elevenlabs_quota_tick, do: Process.send_after(self(), :elevenlabs_quota_tick, @elevenlabs_quota_tick_ms)

  @doc false
  @spec github_quota_snapshot() :: term()
  def github_quota_snapshot, do: GitHubQuotaSnapshot.read()
end
