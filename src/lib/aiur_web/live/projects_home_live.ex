defmodule AiurWeb.ProjectsHomeLive do
  @moduledoc """
  Every project on one screen: this gateway rendered here, each peer gateway filled in by the browser.

  Peers are fetched client-side (`projects-home-hook.js`) so an unreachable peer never delays the page.
  An unreadable value is shown as unknown, never as zero.
  """
  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias Aiur.Gateway.Summary
  alias AiurWeb.OperatorControlCenter.{AwaitingCommands, DashboardShell, NavState, Overview, RouteRegistry}
  alias AiurWeb.ProjectsHome.Peers

  @tick_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> DashboardShell.mount()
      |> AwaitingCommands.mount(connected?(socket))
      |> assign(:current_route, RouteRegistry.current_route(:projects))
      |> assign(:analytics, AiurWeb.Presenter.analytics_navigation())
      |> assign(:tracker_kind, safe(&Aiur.Config.tracker_kind/0, "tracker unavailable"))
      |> assign(:agent_kind, safe(&Aiur.Config.agent_kind/0, "agent unavailable"))
      |> assign(:summary, local_summary())
      |> assign(:peers_json, Jason.encode!(Peers.list()))

    if connected?(socket), do: Process.send_after(self(), :projects_home_tick, @tick_ms)
    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, :current_route, RouteRegistry.current_route(:projects))}

  @impl true
  def handle_info({:decision_changed, _id, _version}, socket), do: {:noreply, AwaitingCommands.refresh(socket)}
  def handle_info(:awaiting_commands_tick, socket), do: {:noreply, AwaitingCommands.tick(socket)}

  def handle_info(:projects_home_tick, socket) do
    Process.send_after(self(), :projects_home_tick, @tick_ms)
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
      <section id="projects-home" class="section-card" aria-labelledby="projects-home-title">
        <h2 id="projects-home-title">Projects</h2>
        <%= case @summary do %>
          <% {:ok, summary} -> %>
            <div id="projects-home-local" class="bo-state-card" data-gateway-card="local" data-connectivity="online" data-running={summary.capacity.running} data-max={summary.capacity.max}>
              <h3>{summary.gateway_label || "This gateway"}</h3>
              <p>online · {summary.workload || "workload unknown"} · {count(summary.capacity.running)} of {count(summary.capacity.max)} agents</p>
              <a href="/build">Open Build ›</a>
              <p :if={summary.projects == []}>No projects reported.</p>
              <ul>
                <li :for={project <- summary.projects} data-project-row={project.repo}>
                  {project.repo} · running {count(project.running)} · ready {count(project.ready)}
                  <a href="/build">Build ›</a>
                </li>
              </ul>
            </div>
          <% :unavailable -> %>
            <div class="bo-state-card" data-gateway-card="local" data-empty-reason="local_summary_unavailable">
              <h3>This gateway</h3>
              <p>local summary unavailable</p>
              <a href="/build">Build ›</a>
            </div>
        <% end %>
        <div id="projects-home-peers" phx-hook="ProjectsHome" phx-update="ignore" data-peers={@peers_json}>
          <p data-totals></p>
          <div data-cards></div>
        </div>
        <p data-section="agents">Current agents, queue and Decisions: not in this gateway's summary yet.</p>
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
