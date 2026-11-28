defmodule AiurWeb.ExecutorLive do
  @moduledoc """
  The Executor footer: a sticky child LiveView rendered by the app layout on every
  dashboard page. Collapsed it shows the Executor's state; expanded it shows the latest
  events and the conversation. The status snapshot refreshes independently of history.
  """
  use Phoenix.LiveView
  alias Aiur.Conversation.Ref
  alias Aiur.Executor.{BackgroundAgents, Blockers, SessionIngest, Status}
  alias AiurWeb.Conversation.{Components, Composer, Navigation, Session}
  alias AiurWeb.{ConversationLive, EndpointConfig, ExecutorView}
  alias AiurWeb.Executor.{BackgroundAgentsPanel, BlockersPanel, StatusHeader}
  alias Phoenix.LiveView.AsyncResult
  alias Phoenix.LiveView.JS

  on_mount(AiurWeb.DashboardPagesGate)

  @status_interval_ms 5_000
  @status_timeout_ms 2_000

  @impl true
  def mount(_params, session, socket) do
    socket = assign(socket, :executor_footer?, true)
    {:ok, socket} = Session.mount(Ref.conversation_id(Ref.executor()), session, socket)
    # A nested LiveView gets no handle_params, which is where a page loads its tail.
    socket = if connected?(socket), do: Navigation.params(socket, %{}), else: socket
    socket = assign(socket, blockers: AsyncResult.loading(), background_agents: AsyncResult.loading(), panels_now: DateTime.utc_now())
    socket = assign(socket, executor_status: :loading, status_read: :idle)
    socket = if connected?(socket), do: socket |> subscribe_status() |> load_panels(), else: socket
    refresh({:ok, socket})
  end

  @impl true
  def handle_event("retry_executor_status", _params, socket), do: {:noreply, load_status(socket)}
  def handle_event(event, params, socket), do: ConversationLive.handle_event(event, params, socket) |> refresh()

  @impl true
  def handle_info(:age_tick, socket), do: ConversationLive.handle_info(:age_tick, socket) |> refresh_panels()

  def handle_info(:executor_status_tick, socket) do
    Process.send_after(self(), :executor_status_tick, @status_interval_ms)
    {:noreply, load_status(socket)}
  end

  def handle_info({:executor_hook, _event}, socket), do: {:noreply, load_status(socket)}

  def handle_info({:decision_changed, id, _version} = message, socket) do
    {:noreply, updated} = ConversationLive.handle_info(message, socket)

    if Enum.any?(socket.assigns.decision_page.decisions ++ updated.assigns.decision_page.decisions, &(&1.decision_id == id)) do
      refresh_panels({:noreply, updated})
    else
      refresh({:noreply, updated})
    end
  end

  def handle_info(message, socket), do: ConversationLive.handle_info(message, socket) |> refresh()

  @impl true
  def handle_async(:executor_status, result, socket) do
    snapshot =
      case result do
        {:ok, snapshot} -> snapshot
        {:exit, _reason} -> :unavailable
      end

    pending? = socket.assigns.status_read == :queued
    socket = assign(socket, executor_status: snapshot, status_read: :idle)
    {:noreply, if(pending?, do: load_status(socket), else: socket)}
  end

  defp subscribe_status(socket) do
    Phoenix.PubSub.subscribe(Aiur.PubSub, SessionIngest.topic())
    Process.send_after(self(), :executor_status_tick, @status_interval_ms)
    load_status(socket)
  end

  defp load_status(%{assigns: %{status_read: :idle}} = socket) do
    socket
    |> assign(:status_read, :reading)
    |> start_async(:executor_status, &read_status/0)
  end

  defp load_status(socket), do: assign(socket, :status_read, :queued)

  defp read_status do
    task = Aiur.Project.Task.async(&Status.snapshot/0)

    case Task.yield(task, @status_timeout_ms) do
      {:ok, snapshot} ->
        snapshot

      {:exit, _reason} ->
        :unavailable

      nil ->
        Task.shutdown(task, :brutal_kill)
        :unavailable
    end
  end

  defp refresh_panels({reply, socket}), do: refresh({reply, load_panels(socket)})

  defp load_panels(socket) do
    store = EndpointConfig.get(:decision_store) || Aiur.Commands.default_store()
    now = DateTime.utc_now()

    socket
    |> assign(:panels_now, now)
    |> assign_async(:blockers, fn -> {:ok, %{blockers: Blockers.snapshot(store: store, now: now)}} end)
    |> assign_async(:background_agents, fn -> {:ok, %{background_agents: BackgroundAgents.snapshot()}} end)
  end

  defp refresh({reply, socket}), do: {reply, assign(socket, :executor_frame, ExecutorView.present(socket.assigns))}

  @impl true
  def render(assigns) do
    status = assigns.executor_status

    assigns =
      assign(assigns,
        summary: ExecutorView.summary(assigns.executor_frame),
        compact_status?:
          match?(%{binding: %{state: state}} when state in ["attached", "detached"], status) ||
            (assigns.executor_frame.state in [:live, :idle, :known_empty] && (status == :unavailable || match?(%{binding: :unavailable}, status)))
      )

    ~H"""
    <aside id="executor-footer" class="executor-footer" phx-hook="ExecutorFooter" data-state={@executor_frame.state}
      data-freshness={@executor_frame.age.freshness} aria-label="Executor"
      phx-mounted={JS.ignore_attributes(["data-open"]) |> JS.ignore_attributes(["aria-expanded", "aria-label"], to: "#executor-footer-toggle") |> JS.ignore_attributes(["hidden"], to: "#executor-footer-panel")}>
      <div class="executor-footer__bar">
        <span class="executor-footer__label">Executor</span>
        <span class="executor-footer__state">
          <span class="executor-footer__dot" aria-hidden="true"></span>
          <span id="executor-footer-state">
            <StatusHeader.header :if={@compact_status?} snapshot={@executor_status} compact />
            <span :if={not @compact_status?} role="status">{@summary}</span>
          </span>
        </span>
        <button id="executor-footer-toggle" class="executor-footer__toggle" type="button" aria-expanded="false"
          aria-controls="executor-footer-panel" aria-label="Expand Executor panel" data-executor-footer-toggle>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m6 15 6-6 6 6"/></svg>
        </button>
      </div>
      <div id="executor-footer-panel" class="executor-footer__panel" hidden>
        <div class="executor-footer__overview">
          <section id="executor-status-header" aria-label="Executor status">
            <StatusHeader.header snapshot={@executor_status} retry="retry_executor_status" />
          </section>
          <ExecutorView.notices view={@executor_frame} writable={@writable} />
        </div>
        <BlockersPanel.panel :if={@blockers.ok? and !@blockers.failed} snapshot={@blockers.result} decisions={@decision_page.decisions} actions={@decision_actions} writable={@writable} />
        <p :if={@blockers.failed} role="status">Executor blockers unavailable</p>
        <BackgroundAgentsPanel.panel :if={@background_agents.ok? and !@background_agents.failed} snapshot={@background_agents.result} now={@panels_now} />
        <p :if={@background_agents.failed} role="status">Background agents unavailable</p>
        <section class="executor-footer__events" aria-label="Latest Executor events">
          <h2>Latest events</h2>
          <ul id="executor-footer-events" phx-update="stream">
            <li :for={{dom_id, anchor} <- @streams.events} id={"executor-footer-" <> dom_id} data-kind={anchor["kind"]}>
              <time>{anchor["event"]["observed_at"]}</time>
              <a :if={is_integer(anchor["pos"])} href={"/conversations/#{@id}?pos=#{anchor["pos"]}"}>{ExecutorView.event_label(anchor)}</a>
              <span :if={not is_integer(anchor["pos"])}>{ExecutorView.event_label(anchor)}</span>
            </li>
          </ul>
          <p class="executor-footer__empty">No Executor events yet</p>
        </section>
        <section :if={@executor_frame.state != :not_opted_in} class="executor-footer__conversation" aria-label="Executor conversation">
          <h2>Conversation <a href={"/conversations/#{@id}"}>Open full history</a></h2>
          <div id="executor-footer-entries" phx-update="stream">
            <div :for={{id, entry} <- @streams.entries} id={id}>
              <Components.entry entry={entry} sessions={@sessions} can_reveal={@can_reveal} />
            </div>
          </div>
          <Composer.composer writable={@writable} target={@composer_target} draft={@draft} overlay={@delivery_overlay} listener={@composer_listener} capability={@composer_capability} />
        </section>
      </div>
    </aside>
    """
  end
end
