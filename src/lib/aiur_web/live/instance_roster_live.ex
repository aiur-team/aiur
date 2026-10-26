defmodule AiurWeb.InstanceRosterLive do
  @moduledoc "Read-only dashboard view of instances registered in the shared lease store."
  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias Aiur.Instance.Roster.Presentation
  alias AiurWeb.InstanceRosterData
  alias AiurWeb.OperatorControlCenter.{AwaitingCommands, DashboardShell, NavState, Overview, RouteRegistry}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> DashboardShell.mount()
      |> AwaitingCommands.mount(connected?(socket))
      |> assign(:current_route, RouteRegistry.current_route(:instances))
      |> assign(:analytics, AiurWeb.Presenter.analytics_navigation())
      |> assign(:tracker_kind, safe(&Aiur.Config.tracker_kind/0, "tracker unavailable"))
      |> assign(:agent_kind, safe(&Aiur.Config.agent_kind/0, "agent unavailable"))
      |> assign(:roster, InstanceRosterData.read())

    if connected?(socket), do: Process.send_after(self(), :instance_roster_tick, 10_000)
    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, :current_route, RouteRegistry.current_route(:instances))}

  @impl true
  def handle_info({:decision_changed, _id, _version}, socket), do: {:noreply, AwaitingCommands.refresh(socket)}
  def handle_info(:awaiting_commands_tick, socket), do: {:noreply, AwaitingCommands.tick(socket)}

  def handle_info(:instance_roster_tick, socket) do
    Process.send_after(self(), :instance_roster_tick, 10_000)
    {:noreply, assign(socket, :roster, InstanceRosterData.read())}
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
      <section id="instance-roster" class="section-card" aria-labelledby="instance-roster-title">
        <h2 id="instance-roster-title">Instances</h2>
        <%= case @roster do %>
          <% {:ok, roster} -> %>
            <p>Observed at {DateTime.to_iso8601(roster.observed_at)} (age {roster.age_ms} ms)</p>
            <p :if={roster.instances == []}>No instances have published a heartbeat.</p>
            <div :for={instance <- roster.instances} class="bo-state-card" data-instance-state={instance.state} data-age-ms={instance.age_ms}>
              <h3>{instance.instance_id} <span :if={instance.state == :stale}>(stale)</span></h3>
              <p>Version {instance.version}; heartbeat {age(instance.age_ms)} ago.</p>
              <p>Host: {instance.host_kind || "unknown"}; public URL: {instance.public_url || "unavailable"}</p>
              <p>Leader: {Presentation.leader_label(instance.leader?)}; agents: {Presentation.count(instance.agent_count)} / {Presentation.count(instance.agent_capacity)}</p>
              <p>Held tickets: {held_tickets(instance.held_tickets)}</p>
              <ul :if={is_list(instance.agents)} aria-label={"Agents on #{instance.instance_id}"}>
                <li :for={agent <- instance.agents} data-agent-instance={instance.instance_id} data-observation-age-ms={instance.age_ms}>
                  {agent["identifier"] || "unknown ticket"} — {agent["state"] || "unknown"} — {instance.instance_id} (observed {age(instance.age_ms)} ago)
                </li>
              </ul>
            </div>
          <% :disabled -> %>
            <p data-empty-reason="lease_store_disabled">Instance roster is unavailable because no shared lease store is configured.</p>
          <% {:error, _reason} -> %>
            <p role="alert" data-empty-reason="lease_store_unavailable">Instance roster could not be read from the shared lease store.</p>
        <% end %>
      </section>
    </DashboardShell.dashboard_shell>
    """
  end

  defp age(ms) when is_integer(ms) and ms < 60_000, do: "#{div(ms, 1_000)} seconds"
  defp age(ms) when is_integer(ms), do: "#{div(ms, 60_000)} minutes"
  defp held_tickets(tickets) when is_list(tickets) and tickets != [], do: Enum.join(tickets, ", ")
  defp held_tickets([]), do: "none"
  defp held_tickets(_), do: "unknown"

  defp safe(fun, fallback) do
    fun.() |> to_string()
  rescue
    _error -> fallback
  end
end
