defmodule AiurWeb.GatewayLive do
  @moduledoc """
  One gateway per card: connectivity and workload as two separate fields, capacity, projects, health,
  and pause controls. This gateway renders server-side; each peer is filled in by the browser
  (`gateway-view-hook.js`), which holds the session a peer needs. `?gateway=<name>` selects one.

  The gateway summary has no agent list or local queue yet, so those say so rather than showing zero.
  """
  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias Aiur.Gateway.{Liveness, Summary}
  alias Aiur.Instance.Roster
  alias Aiur.Orchestrator.Client
  alias AiurWeb.OperatorControlCenter.{AwaitingCommands, DashboardShell, NavState, Overview, RouteRegistry}
  alias AiurWeb.ProjectsHome.Peers

  @tick_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> DashboardShell.mount()
      |> AwaitingCommands.mount(connected?(socket))
      |> assign(:current_route, RouteRegistry.current_route(:gateways))
      |> assign(:analytics, AiurWeb.Presenter.analytics_navigation())
      |> assign(:tracker_kind, safe(&Aiur.Config.tracker_kind/0, "tracker unavailable"))
      |> assign(:agent_kind, safe(&Aiur.Config.agent_kind/0, "agent unavailable"))
      |> assign(:summary, local_summary())
      |> assign(:selected, nil)

    if connected?(socket), do: Process.send_after(self(), :gateway_tick, @tick_ms)
    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    peers = Peers.list()
    selected = params["gateway"]
    summary = socket.assigns.summary
    known? = is_nil(selected) or selected == "local" or Enum.any?(peers, &(&1.name == selected)) or local_id(summary) == selected

    {:noreply,
     socket
     |> assign(:current_route, RouteRegistry.current_route(:gateways))
     |> assign(:selected, selected)
     |> assign(:known?, known?)
     |> assign(:show_local?, is_nil(selected) or selected == "local" or local_id(summary) == selected)
     |> assign(:peers_json, Jason.encode!(Enum.map(peers, &Map.put(&1, :offline, offline?(&1)))))}
  end

  @impl true
  def handle_info({:decision_changed, _id, _version}, socket), do: {:noreply, AwaitingCommands.refresh(socket)}
  def handle_info(:awaiting_commands_tick, socket), do: {:noreply, AwaitingCommands.tick(socket)}

  def handle_info(:gateway_tick, socket) do
    Process.send_after(self(), :gateway_tick, @tick_ms)
    {:noreply, assign(socket, :summary, local_summary())}
  end

  def handle_info(message, socket), do: DashboardShell.handle_info(message, socket)

  @impl true
  def handle_event("toggle-global-pause", _params, socket), do: {:noreply, DashboardShell.toggle_pause(socket)}
  def handle_event("toggle-nav", _params, socket), do: {:noreply, NavState.toggle(socket)}
  def handle_event("restore-nav", %{"collapsed" => collapsed}, socket), do: {:noreply, NavState.restore(socket, collapsed)}

  @impl true
  def render(assigns) do
    ~H"""
    <DashboardShell.dashboard_shell route={@current_route} routes={RouteRegistry.routes(@analytics)} tracker_kind={@tracker_kind} agent_kind={@agent_kind} nav_collapsed={@nav_collapsed} nav_counts={@nav_counts} pause_state={DashboardShell.pause_state(assigns)}>
      <:banner><Overview.decisions_banner retained_counts={@retained_counts} navigate /></:banner>
      <section id="gateway-view" class="section-card" aria-labelledby="gateway-view-title">
        <h2 id="gateway-view-title">Gateways</h2>
        <%= if @known? do %>
          <p :if={@selected}><a href="/gateways">‹ All gateways</a></p>
          <button :if={is_nil(@selected)} type="button" data-action="pause-all">Pause all</button>
          <div id="gateway-report" data-report role="status" phx-update="ignore"></div>
          <%= if @show_local? do %>
            <%= case @summary do %>
              <% {:ok, summary} -> %>
                <div class="bo-state-card" data-gateway-card="local" data-connectivity="online">
                  <h3>{summary.gateway_label || "This gateway"}</h3>
                  <p data-field="connectivity">online</p>
                  <p data-field="workload">{summary.workload || "workload unknown"}</p>
                  <p data-field="capacity">{count(summary.capacity.running)} of {count(summary.capacity.max)} agents</p>
                  <p data-field="health">{health()}</p>
                  <ul>
                    <li :for={project <- summary.projects} data-project-row={project.repo}>{project.repo} · running {count(project.running)}</li>
                  </ul>
                  <p data-section="agents">Agents and local queue: not in this gateway's summary yet.</p>
                  <button type="button" data-action="pause-gateway" data-gateway="local">Pause {summary.gateway_label || "this gateway"}</button>
                  <span data-pause-result="local" role="status"></span>
                </div>
              <% :unavailable -> %>
                <div class="bo-state-card" data-gateway-card="local">
                  <h3>This gateway</h3>
                  <p data-field="connectivity">unknown</p>
                  <p data-field="workload">workload unknown</p>
                </div>
            <% end %>
          <% end %>
          <div id="gateway-peers" phx-hook="GatewayView" phx-update="ignore" data-peers={@peers_json} data-selected={if @selected not in [nil, "local"], do: @selected} data-local-name="local" data-local-label={local_label(@summary)}>
            <div data-cards></div>
          </div>
        <% else %>
          <p data-empty-reason="unknown_gateway">unknown gateway</p>
          <a href="/gateways">‹ All gateways</a>
        <% end %>
      </section>
    </DashboardShell.dashboard_shell>
    """
  end

  defp local_summary do
    {:ok, Summary.build()}
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  defp local_id({:ok, %{gateway_id: id}}), do: id
  defp local_id(_), do: nil

  defp local_label({:ok, %{gateway_label: label}}) when is_binary(label), do: label
  defp local_label(_), do: "This gateway"

  # Pause state is the gateway's own truth; an orchestrator that does not answer is unknown, not "dispatching".
  defp health do
    case Client.global_pause_status() do
      {:ok, %{globally_paused: true}} -> "paused"
      {:ok, %{globally_paused: false}} -> "dispatching"
      _ -> "unknown"
    end
  end

  defp offline?(%{gateway_id: nil}), do: false

  defp offline?(%{gateway_id: id}) do
    case Roster.list() do
      {:ok, view} -> id in Liveness.offline_ids(view, Liveness.threshold_ms())
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp count(value) when is_integer(value), do: Integer.to_string(value)
  defp count(_), do: "unknown"

  defp safe(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    :exit, _ -> fallback
  end
end
