defmodule AiurWeb.BuildLive do
  @moduledoc "Authenticated build home shell with hook-owned content and a bounded initial read."

  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  require Logger

  alias AiurWeb.Build.{DataSource, Protocol, Read, URLState, UsageUpdates}
  alias AiurWeb.BuildOrder.Runtime
  alias AiurWeb.OperatorControlCenter.{AwaitingCommands, DashboardShell, NavState, RouteRegistry}
  alias AiurWeb.Presenter

  @snapshot_timeout_ms 15_000
  @route %{id: :build, label: "Build", icon: "", description: "", path: "/build", type: :live, owner: :build, availability: :available, active_actions: [:build]}

  @impl true
  def mount(_params, _session, socket) do
    connected = connected?(socket)

    socket =
      socket
      |> Protocol.init()
      |> UsageUpdates.init(connected)
      |> NavState.assign_nav()
      |> AwaitingCommands.mount(connected)
      |> assign(build_state: :loading, build_snapshot: nil, route: @route, tracker_kind: Runtime.tracker_kind(), agent_kind: Runtime.agent_kind(), analytics: Presenter.analytics_navigation())

    {:ok, if(connected, do: load_snapshot(socket), else: socket)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    home = if URLState.legacy?(params), do: Map.merge(URLState.legacy_preset(params), Map.drop(params, ~w(v scope conditions))), else: params
    state = URLState.parse(home)
    previous = socket.assigns[:url_state]
    location = URI.parse(uri)
    socket = assign(socket, url_path: location.path, url_state: state)
    socket = if previous != nil and previous != state and connected?(socket), do: push_event(socket, "build:url", %{state: state}), else: socket
    {:noreply, patch_url(socket, location.query || "", URLState.to_query(state))}
  end

  defp patch_url(socket, current, query) do
    if current == query do
      socket
    else
      path = socket.assigns.url_path <> if(query == "", do: "", else: "?" <> query)
      push_patch(socket, to: path, replace: true)
    end
  end

  defp corrected_url?(params, query) do
    sent = Map.reject(params, fn {key, value} -> key == "ticket" or not is_binary(value) or value == "" end)
    Map.take(URI.decode_query(query), Map.keys(sent)) != sent
  end

  defp load_snapshot(socket) do
    source = socket.assigns.build_source
    opts = source_opts(socket)

    case DataSource.call(source, :subscribe, [opts]) do
      :ok -> :ok
      {:error, _reason} -> Logger.warning("build home subscription unavailable")
    end

    Process.send_after(self(), :build_snapshot_timeout, @snapshot_timeout_ms)
    start_async(socket, :build_snapshot, fn -> DataSource.call(source, :snapshot, [opts]) end)
  end

  @impl true
  def handle_async(:build_snapshot, {:ok, {:ok, data}}, %{assigns: %{build_state: :loading}} = socket) do
    socket = assign(socket, build_state: :ready)
    {:noreply, if(socket.assigns.build_resynced, do: socket, else: Protocol.store(socket, data))}
  end

  def handle_async(:build_snapshot, {:ok, {:error, reason}}, %{assigns: %{build_state: :loading}} = socket),
    do: {:noreply, unavailable(socket, reason_tag(reason))}

  def handle_async(:build_snapshot, {:exit, _reason}, %{assigns: %{build_state: :loading}} = socket),
    do: {:noreply, unavailable(socket, "crashed")}

  def handle_async(:build_snapshot, _result, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:build_snapshot_timeout, %{assigns: %{build_state: :loading}} = socket),
    do: {:noreply, socket |> cancel_async(:build_snapshot) |> unavailable("timeout")}

  def handle_info({:build_changes, changes}, socket), do: {:noreply, Protocol.changes(socket, changes, source_opts(socket))}

  def handle_info({AiurWeb.FinancialData, :updated, _} = message, socket), do: {:noreply, UsageUpdates.queue(socket, message)}
  def handle_info(:build_usage_flush, socket), do: {:noreply, UsageUpdates.flush(socket)}
  def handle_info(tick, socket) when tick in [:build_usage_github_tick, :build_usage_elevenlabs_tick], do: {:noreply, UsageUpdates.tick(socket, tick)}

  def handle_info({:decision_changed, _id, _version}, socket), do: {:noreply, AwaitingCommands.refresh(socket)}
  def handle_info(:awaiting_commands_tick, socket), do: {:noreply, AwaitingCommands.tick(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("build-resync", _params, socket), do: Protocol.resync(socket, source_opts(socket))
  def handle_event("load-earlier", params, socket), do: Protocol.earlier(socket, params, source_opts(socket))
  def handle_event("usage-watch-start", _params, socket), do: {:noreply, UsageUpdates.watch(socket, :start)}
  def handle_event("usage-watch-stop", _params, socket), do: {:noreply, UsageUpdates.watch(socket, :stop)}

  def handle_event("build:url", params, socket) when is_map(params) do
    previous = socket.assigns.url_state
    state = params |> Map.put_new("ticket", previous.ticket) |> URLState.parse()
    query = URLState.to_query(state)
    socket = assign(socket, :url_state, state)
    socket = if corrected_url?(params, query), do: push_event(socket, "build:url", %{state: state}), else: socket
    {:noreply, patch_url(socket, URLState.to_query(previous), query)}
  end

  def handle_event("toggle-nav", _params, socket), do: {:noreply, NavState.toggle(socket)}

  def handle_event("restore-nav", %{"collapsed" => collapsed}, socket),
    do: {:noreply, NavState.restore(socket, collapsed)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp source_opts(socket), do: Read.source_opts(socket)

  defp unavailable(socket, tag) do
    Logger.warning("build home snapshot unavailable reason=#{tag}")
    assign(socket, :build_state, {:unavailable, tag})
  end

  defp reason_tag(:not_wired), do: "not_wired"
  defp reason_tag(:timeout), do: "timeout"
  defp reason_tag(_reason), do: "unknown"
  defp state_name({:unavailable, _tag}), do: "unavailable"
  defp state_name(state), do: Atom.to_string(state)
  defp reason({:unavailable, tag}), do: tag
  defp reason(_state), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <DashboardShell.dashboard_shell route={@route} routes={RouteRegistry.routes(@analytics)}
      tracker_kind={@tracker_kind} agent_kind={@agent_kind}
      nav_collapsed={@nav_collapsed} nav_counts={@nav_counts}>
      <div id="build-root" class="bd-root" phx-hook="BuildHome" phx-update="ignore"
        data-url-state={Jason.encode!(@url_state)} data-build-state={state_name(@build_state)} data-build-reason={reason(@build_state)}>
        <div id="bd-usage"></div><div id="bd-offline"></div><div id="bd-fh"></div>
        <div class="bd-toolbar"><div class="bd-bar-l" id="bd-tools-l"></div><div class="bd-filters" id="bd-filters"></div><div class="bd-bar-r" id="bd-tools"></div></div>
        <div class="bd-vpw"><div class="bd-vp" id="bd-vp">
          <div class="bd-lanes"><div class="bd-skel-lanes"><i class="bd-skel-i" style="background: var(--surface-3)"></i><i style="background: var(--surface-3)"></i><i style="background: var(--surface-3)"></i><i style="background: var(--surface-3)"></i></div></div>
          <div class="bd-skel"><i :for={_ <- 1..16}></i></div>
          <div class="bd-loading"><span class="bd-spin"></span>Loading build timeline…</div>
        </div><div class="bd-sb" id="bd-sb"><i></i></div><div class="bd-tree" id="bd-tree" hidden></div></div>
        <div class="bd-status" id="bd-status"></div>
      </div>
    </DashboardShell.dashboard_shell>
    <div id="usage-watch" phx-hook="UsageWatch" hidden></div>
    <div class="tk-backdrop" id="tk-backdrop" phx-update="ignore">
      <div class="tk-modal" id="tk-modal" role="dialog" aria-modal="true" aria-label="Ticket context">
        <header class="tk-head" id="tk-head"></header>
        <div class="tk-body" id="tk-body"></div>
      </div>
    </div>
    """
  end
end
