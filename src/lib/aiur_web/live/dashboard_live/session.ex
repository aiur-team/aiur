defmodule AiurWeb.DashboardLive.Session do
  @moduledoc false

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  alias AiurWeb.DashboardLive.CommandHistory
  alias AiurWeb.DashboardLive.Commands
  alias AiurWeb.DashboardLive.RepositoryLeaderBanner
  alias AiurWeb.DashboardLive.UnitsPanel
  alias AiurWeb.DashboardLive.Voice
  alias AiurWeb.EndpointConfig
  alias AiurWeb.OperatorControlCenter.NavState
  alias AiurWeb.OperatorControlCenter.PayloadLoader
  alias AiurWeb.OperatorControlCenter.RouteRegistry

  @runtime_tick_ms 1_000
  # Refresh Commands even if a projection notification was missed.
  @github_quota_tick_ms 15_000
  # Whole-account voice credit changes more slowly than the GitHub budget.
  @elevenlabs_quota_tick_ms 60_000

  @doc false
  @spec mount(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(socket) do
    socket = NavState.assign_nav(socket)
    connected = connected?(socket)

    socket = AiurWeb.RefreshSubscriptions.dashboard(socket)

    payload = PayloadLoader.load(if connected, do: :join, else: :cached)

    socket =
      socket
      |> assign(%{
        payload: payload,
        now: DateTime.utc_now(),
        repository_leader: RepositoryLeaderBanner.initial_status()
      })
      |> assign(:time_zone, browser_time_zone(socket))
      |> Voice.assign_voice()
      |> assign(:decision_actions, %{})
      |> assign(:global_pause_error, nil)
      |> assign(:payload_reload_scheduled?, false)
      |> assign(:payload_reload_mode, :cached)
      |> assign(%{writable: dashboard_writable?(), live_connected: connected})
      |> assign(:decision_filter, :all)
      |> assign(:decision_page, Commands.empty_decision_page())
      |> assign(:decision_query, %{})
      |> CommandHistory.init_history_rows()
      |> UnitsPanel.assign_units_view()
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
  def handle_params(params, _uri, socket) do
    filter = Commands.normalize_filter(params["route"] || params["filter"])

    {:noreply,
     socket
     |> assign(:decision_filter, filter)
     |> assign(:table_sort, UnitsPanel.normalize_table_sort(params["sort"]))
     |> assign(:current_route, RouteRegistry.current_route(Map.get(socket.assigns, :live_action)))
     |> Commands.assign_decision_page(filter, params)
     |> CommandHistory.load_history(:first_page)
     |> Commands.assign_selected_decision(params["decision_id"])}
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

  @spec schedule_github_quota_tick() :: reference()
  def schedule_github_quota_tick, do: Process.send_after(self(), :github_quota_tick, @github_quota_tick_ms)

  @doc false
  @spec schedule_elevenlabs_quota_tick() :: term()
  def schedule_elevenlabs_quota_tick, do: Process.send_after(self(), :elevenlabs_quota_tick, @elevenlabs_quota_tick_ms)
end
