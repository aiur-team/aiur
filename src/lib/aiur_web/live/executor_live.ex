defmodule AiurWeb.ExecutorLive do
  @moduledoc """
  The Executor footer: a sticky child LiveView rendered by the app layout on every
  dashboard page. Collapsed it shows the Executor's state; expanded it shows the latest
  events and the conversation. It reuses the shared conversation session and its
  subscriptions, so it adds no polling of its own.
  """
  use Phoenix.LiveView
  alias Aiur.Conversation.Ref
  alias AiurWeb.Conversation.{Components, Composer, Navigation, Session}
  alias AiurWeb.{ConversationLive, ExecutorView}
  alias Phoenix.LiveView.JS

  on_mount(AiurWeb.DashboardPagesGate)

  @impl true
  def mount(_params, session, socket) do
    {:ok, socket} = Session.mount(Ref.conversation_id(Ref.executor()), session, socket)
    # A nested LiveView gets no handle_params, which is where a page loads its tail.
    socket = if connected?(socket), do: Navigation.params(socket, %{}), else: socket
    refresh({:ok, socket})
  end

  @impl true
  def handle_event(event, params, socket), do: ConversationLive.handle_event(event, params, socket) |> refresh()
  @impl true
  def handle_info(message, socket), do: ConversationLive.handle_info(message, socket) |> refresh()

  defp refresh({reply, socket}), do: {reply, assign(socket, :executor_frame, ExecutorView.present(socket.assigns))}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :summary, ExecutorView.summary(assigns.executor_frame))

    ~H"""
    <aside id="executor-footer" class="executor-footer" phx-hook="ExecutorFooter" data-state={@executor_frame.state}
      data-freshness={@executor_frame.age.freshness} aria-label="Executor"
      phx-mounted={JS.ignore_attributes(["data-open"]) |> JS.ignore_attributes(["aria-expanded", "aria-label"], to: "#executor-footer-toggle") |> JS.ignore_attributes(["hidden"], to: "#executor-footer-panel")}>
      <div class="executor-footer__bar">
        <span class="executor-footer__label">Executor</span>
        <span class="executor-footer__state" role="status">
          <span class="executor-footer__dot" aria-hidden="true"></span>
          <span id="executor-footer-state">{@summary}</span>
        </span>
        <button id="executor-footer-toggle" class="executor-footer__toggle" type="button" aria-expanded="false"
          aria-controls="executor-footer-panel" aria-label="Expand Executor panel" data-executor-footer-toggle>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m6 15 6-6 6 6"/></svg>
        </button>
      </div>
      <div id="executor-footer-panel" class="executor-footer__panel" hidden>
        <ExecutorView.notices view={@executor_frame} writable={@writable} />
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
