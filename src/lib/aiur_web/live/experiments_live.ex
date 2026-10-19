defmodule AiurWeb.ExperimentsLive do
  @moduledoc "Read-only experiment index and evidence shell."
  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias AiurWeb.Experiments.{ChartPanel, Report, Source, Styles}
  alias AiurWeb.OperatorControlCenter.{AwaitingCommands, DashboardShell, NavState, Overview, RouteRegistry}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Source.subscribe()

    {:ok,
     socket
     |> NavState.assign_nav()
     |> AwaitingCommands.mount(connected?(socket))
     |> assign(:analytics, AiurWeb.Presenter.analytics_navigation())
     |> assign(:tracker_kind, "")
     |> assign(:agent_kind, "")
     |> assign(:selected_id, nil)
     |> assign(:detail, nil)
     |> assign(:chart_params, %{})
     |> assign(:chart_metric, nil)
     |> load_index()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    id = params["id"]
    socket = socket |> assign(:chart_params, Map.take(params, ["metric", "stratum"])) |> assign(:selected_id, id) |> assign(:current_route, RouteRegistry.current_route(socket.assigns.live_action))
    {:noreply, load_detail(socket, id)}
  end

  @impl true
  def handle_info({:experiments_changed, id}, socket) do
    socket = load_index(socket)
    socket = if is_nil(socket.assigns.selected_id) or id == :all or id == socket.assigns.selected_id, do: load_detail(socket, socket.assigns.selected_id), else: socket
    {:noreply, socket}
  end

  def handle_info({:decision_changed, _id, _version}, socket), do: {:noreply, AwaitingCommands.refresh(socket)}
  def handle_info(:awaiting_commands_tick, socket), do: {:noreply, AwaitingCommands.tick(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle-nav", _params, socket), do: {:noreply, NavState.toggle(socket)}
  def handle_event("restore-nav", %{"collapsed" => collapsed}, socket), do: {:noreply, NavState.restore(socket, collapsed)}

  def handle_event("select-metric", _params, %{assigns: %{detail: nil}} = socket), do: {:noreply, socket}

  def handle_event("select-metric", %{"metric" => metric}, socket) do
    {:noreply, push_patch(socket, to: ChartPanel.path(socket.assigns.detail, metric, socket.assigns.detail.stratum))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <DashboardShell.dashboard_shell route={@current_route} routes={RouteRegistry.routes(@analytics)} tracker_kind={@tracker_kind} agent_kind={@agent_kind} nav_collapsed={@nav_collapsed} nav_counts={@nav_counts}>
      <:banner><Overview.decisions_banner retained_counts={@retained_counts} navigate /></:banner>
      {Phoenix.HTML.raw("<style>" <> Styles.css() <> "</style>")}
      <section id="experiments-page" class="exp-root" data-selection={if @selected_id, do: "detail", else: "index"} aria-label="Experiment collection">
        <h1>Experiments</h1>
        <p :if={@status.capture == :off and @index_error not in [:component_off, :store_unreadable, :read_failed]} class="exp-notice" id="experiments-capture-off" role="status">
          Capture is off. New samples are not being captured; existing experiments remain available.
        </p>
        <div :if={@index_error} class="exp-notice" data-empty-reason={@index_error}>
          <p>{state_copy(@index_error)}</p>
        </div>
        <div :if={!@index_error} class="exp-layout">
          <nav class="exp-index" aria-label="Experiment index">
            <.link :for={item <- @items} patch={"/experiments/" <> URI.encode(item.id, &URI.char_unreserved?/1)} class="exp-link" aria-current={if @detail && @detail.id == item.id, do: "page"}>
              <strong>{item.title}</strong>
              <span class="exp-chips"><span class="exp-chip">{item.kind_label}</span><span class="exp-chip">{item.status}</span></span>
              <span :for={metric <- Enum.take(item.metrics, 3)} class="exp-headline">
                {metric.label}: {metric.change} · {metric.direction} · {metric.sample}
                <span :if={metric.guarded?} class="exp-chip">not enough data</span>
              </span>
              <span :for={label <- item.labels} class="exp-chip">{label}</span>
            </.link>
          </nav>
          <section class="exp-detail" aria-label="Experiment detail">
            <.link :if={@selected_id} patch="/experiments" class="exp-back">← All experiments</.link>
            <div :if={@detail_error} class="exp-notice" data-empty-reason={@detail_error}>
              <p>{state_copy(@detail_error)}</p>
              <.link patch="/experiments">All experiments</.link>
            </div>
            <div :if={@detail} id="exp-detail">
              <h2>{@detail.title}</h2>
              <div class="exp-chips"><span class="exp-chip">{@detail.kind_label}</span><span class="exp-chip">{@detail.status}</span></div>
              <dl>
                <dt>Design</dt><dd>{@detail.design_summary}</dd>
                <div :for={window <- @detail.window_labels} class="exp-window"><dt>{window.label} window</dt><dd>{window.text}</dd></div>
                <dt>Frozen baseline</dt>
                <dd :if={@detail.frozen_baseline == :unknown}>Evidence unavailable</dd>
                <dd :if={is_map(@detail.frozen_baseline)} id="exp-baseline">
                  Revision {@detail.frozen_baseline.revision} · {@detail.frozen_baseline.computed_at || "Unknown time"} · Aiur {@detail.frozen_baseline.aiur_version || "Unknown version"}
                  <span>SHA-256: {@detail.frozen_baseline.sha256 || "Unknown hash"}</span>
                </dd>
                <dt>Minimum samples</dt><dd>{@detail.min_samples}</dd>
                <dt>Hypothesis</dt><dd>{@detail.hypothesis}</dd>
              </dl>
              <p :if={@detail.pack_changed_since_freeze?} class="exp-notice">Metric pack definitions changed since this evidence was frozen.</p>
              <h3>Metric summary</h3>
              <p :if={@detail.metrics == []} class="exp-notice" data-empty-reason="evidence_pending">Analysis evidence is not available yet.</p>
              <table :if={@detail.metrics == [] and @detail.metric_specs != []} class="exp-table">
                <caption>Registered metrics</caption>
                <thead><tr><th scope="col">Metric</th><th scope="col">Unit</th><th scope="col">Expected direction</th><th scope="col">Evidence</th></tr></thead>
                <tbody><tr :for={metric <- @detail.metric_specs}><td data-label="Metric">{metric["label"] || metric["ref"]}</td><td data-label="Unit">{metric["unit"] || "Unknown unit"}</td><td data-label="Expected direction">{metric["direction"]}</td><td data-label="Evidence">Unavailable</td></tr></tbody>
              </table>
              <table :if={@detail.metrics != []} class="exp-table">
                <caption>Metric evidence</caption>
                <thead><tr><th scope="col">Metric</th><th scope="col">Group summary and n</th><th scope="col">Change and samples</th><th scope="col">Contrast and interval</th><th scope="col">p-value and test</th><th scope="col">Effect</th></tr></thead>
                <tbody><tr :for={metric <- @detail.metrics}>
                  <td data-label="Metric">{metric.label} ({metric.unit})<span :for={label <- metric.labels} class="exp-chip">{label}</span></td>
                  <td data-label="Groups"><div :for={group <- metric.groups}>{group.name}: {group.center_label} {group.center}, IQR {group.spread}, n {group.n}</div></td>
                  <td data-label="Change">{metric.change} · {metric.direction} · {metric.sample}<span :if={metric.guarded?}>not enough data</span></td>
                  <td data-label="Contrast and interval">{metric.contrast} · {metric.interval}</td><td data-label="p-value and test">{metric.p} {metric.tests}</td><td data-label="Effect">{metric.effect}</td>
                </tr></tbody>
              </table>
              <ChartPanel.panel detail={@detail} metric={@chart_metric} />
              <Report.card report={@detail.report} />
            </div>
          </section>
        </div>
      </section>
    </DashboardShell.dashboard_shell>
    """
  end

  defp load_index(socket) do
    status = Source.status()
    {items, error} = index(status)
    assign(socket, status: status, items: items, index_error: error)
  end

  defp index(%{store: {:error, :disabled}}), do: {[], :component_off}
  defp index(%{store: {:error, reason}}), do: {[], reason}
  defp index(%{available?: false}), do: {[], :component_off}

  defp index(_status) do
    case Source.index() do
      {:ok, []} -> {[], :no_experiments}
      {:ok, items} -> {items, nil}
      {:error, reason} -> {[], reason}
    end
  end

  defp load_detail(%{assigns: %{index_error: :no_experiments}} = socket, id) when is_binary(id),
    do: socket |> assign(:index_error, nil) |> load_detail(id)

  defp load_detail(%{assigns: %{index_error: error}} = socket, _id) when not is_nil(error), do: assign(socket, detail: nil, detail_error: nil)
  defp load_detail(%{assigns: %{items: [first | _rest]}} = socket, nil), do: load_detail(socket, first.id)

  defp load_detail(socket, id) do
    case Source.detail(id, stratum: socket.assigns.chart_params["stratum"]) do
      {:ok, detail} ->
        metric = Enum.find(detail.chart_metrics, &(&1.ref == socket.assigns.chart_params["metric"])) || List.first(detail.chart_metrics)
        assign(socket, detail: detail, detail_error: nil, chart_metric: metric)

      {:error, reason} ->
        assign(socket, detail: nil, detail_error: reason)
    end
  end

  defp state_copy(:no_experiments),
    do: "No experiments yet. Experiments can begin with a version bump or release, a tagged feature epic merge, or an analyst request. Create one with aiur experiments create."

  defp state_copy(:component_off), do: "Experiments are not enabled."
  defp state_copy(:not_found), do: "Experiment not found."
  defp state_copy(:read_failed), do: "Experiment data could not be loaded."
  defp state_copy(_reason), do: "The experiment state store could not be read."
end
