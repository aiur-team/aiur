defmodule AiurWeb.ConversationLive do
  @moduledoc "Paged durable conversation with a bounded live chronology and listener-mode composer."
  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}
  alias AiurWeb.Conversation.{Components, Composer, ComposerEvents, EventComponents, Navigation, Paging, Presenter}

  @impl true
  def mount(%{"conversation_id" => id}, session, socket) do
    principal = AiurWeb.Conversation.Access.principal(session, socket)

    socket =
      socket
      |> assign(
        id: id,
        principal: principal,
        can_reveal: AiurWeb.Conversation.Access.can_reveal?(principal),
        state: :loading,
        page: nil,
        positions: [],
        revealed: MapSet.new(),
        live_head: 0,
        sessions: [],
        last_entry: nil,
        read_error: nil,
        degraded: false,
        at_bottom: true,
        new_below: 0,
        reason: nil,
        mode: :tail,
        age: Presenter.age(nil, DateTime.utc_now())
      )
      |> stream_configure(:entries, dom_id: &"entry-#{&1.pos}")
      |> stream(:entries, [])
      |> ComposerEvents.init()
      |> Navigation.init()

    if connected?(socket) do
      Process.send_after(self(), :age_tick, 30_000)
      {:ok, socket |> Paging.subscribe() |> Navigation.load()}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if connected?(socket), do: {:noreply, Navigation.params(socket, params)}, else: {:noreply, socket}
  end

  @impl true
  def handle_event("event_filters", %{"kinds" => kinds}, socket), do: {:noreply, Navigation.filters(socket, kinds)}
  def handle_event("latest_events", _, socket), do: {:noreply, Navigation.events(socket, :latest)}
  def handle_event("older_events", _, socket), do: {:noreply, Navigation.events(socket, :older)}

  def handle_event("toggle_event_kind", %{"kind" => kind}, socket) do
    kinds = socket.assigns.visible_kinds
    kinds = if kind in kinds, do: List.delete(kinds, kind), else: kinds ++ [kind]
    socket = Navigation.filters(socket, kinds)
    {:noreply, push_event(socket, "conversation-filters", %{kinds: socket.assigns.visible_kinds})}
  end

  def handle_event("reveal_entry", %{"pos" => pos}, socket), do: {:noreply, Paging.reveal(socket, pos)}
  def handle_event("load_older", _params, socket), do: {:noreply, Paging.load(assign(socket, pending_pos: nil, position_notice: nil), :older)}
  def handle_event("load_newer", _params, socket), do: {:noreply, Paging.load(assign(socket, pending_pos: nil, position_notice: nil), :newer)}
  def handle_event("jump_start", _params, socket), do: {:noreply, socket |> Navigation.clear() |> Paging.load(:start) |> push_event("conversation-start", %{})}
  def handle_event("jump_latest", _params, socket), do: {:noreply, socket |> Navigation.clear() |> Paging.load(:tail) |> push_event("conversation-bottom", %{})}
  def handle_event("retry", _params, socket), do: {:noreply, socket |> Paging.subscribe() |> Paging.load(:tail)}
  def handle_event("draft", %{"text" => text}, socket), do: {:noreply, ComposerEvents.draft(socket, text)}
  def handle_event("send", %{"text" => text}, socket), do: {:noreply, ComposerEvents.send_message(socket, text)}

  def handle_event("at_bottom", %{"value" => bottom}, socket) when is_boolean(bottom) do
    {:noreply, assign(socket, at_bottom: bottom, new_below: if(bottom, do: 0, else: socket.assigns.new_below))}
  end

  @impl true
  def handle_info({:entries_appended, id, entries}, %{assigns: %{id: id}} = socket),
    do: {:noreply, socket |> ComposerEvents.reconcile(entries) |> Paging.append(entries) |> Navigation.retry()}

  def handle_info({:anchor_added, id, anchor}, %{assigns: %{id: id}} = socket), do: {:noreply, Navigation.added(socket, anchor)}

  def handle_info(:delivery_tick, socket), do: {:noreply, ComposerEvents.poll(socket)}

  def handle_info({:session_changed, id, _session}, %{assigns: %{id: id}} = socket) do
    {:noreply, Paging.refresh_sessions(socket)}
  end

  def handle_info({:journal_degraded, id, degraded}, %{assigns: %{id: id}} = socket) do
    {:noreply, socket |> assign(:degraded, degraded) |> Paging.present()}
  end

  def handle_info(:age_tick, socket) do
    Process.send_after(self(), :age_tick, 30_000)
    {:noreply, socket |> Paging.present() |> ComposerEvents.refresh_mode()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id="conversation" class="conversation-page">
      <a href="/units">Units</a>
      <Components.status state={@state} age={@age} reason={@reason} last_entry={@last_entry} />
      <div :if={@state == :loading} role="status" aria-busy="true" class="conversation-skeleton">Loading conversation…</div>
      <p :if={@page && not @page.complete_from_start} role="note">Earlier history is not available</p>
      <nav :if={@page} aria-label="Conversation paging">
        <button phx-click="jump_start">Jump to start</button>
        <button :if={List.first(@positions, 1) > 1} phx-click="load_older" phx-disable-with="Loading older…">Load older</button>
        <button :if={List.last(@positions, 0) < @page.head_pos} phx-click="load_newer" phx-disable-with="Loading newer…">Load newer</button>
        <button phx-click="jump_latest">Latest entries</button>
      </nav>
      <p :if={@position_notice} id="conversation-position-notice" role="status">{@position_notice}</p>
      <div class="conversation-layout">
        <EventComponents.event_nav streams={@streams} id={@id} visible_kinds={@visible_kinds} event_start={@event_start} event_has_newer={@event_has_newer} error={@anchor_error} />
        <div id="conversation-scroll" phx-hook="ConversationScroll" class="conversation-scroll" data-highlight={@highlight_pos} data-mode={if is_tuple(@mode), do: "around", else: @mode} data-head={@page && @page.head_pos}>
          <div id="conversation-entries" phx-update="stream">
            <div :for={{id, entry} <- @streams.entries} id={id}
              class={@highlight_pos == entry.pos && Navigation.highlight?(@anchors, entry.pos, @jump_placement) && "conversation-highlight"}
              aria-current={if @highlight_pos == entry.pos && Navigation.highlight?(@anchors, entry.pos, @jump_placement), do: "location"}
              data-jump-target={to_string(@highlight_pos == entry.pos && Navigation.highlight?(@anchors, entry.pos, @jump_placement))} >
              <Components.entry entry={entry} sessions={@sessions} can_reveal={@can_reveal} />
              <EventComponents.entry_marker anchors={@anchors} pos={entry.pos} highlight_pos={if Navigation.highlight?(@anchors, entry.pos, @jump_placement), do: nil, else: @highlight_pos} />
            </div>
          </div>
        </div>
      </div>
      <button :if={@new_below > 0} id="conversation-new" phx-click="jump_latest">{@new_below} new entries below</button>
      <Composer.composer writable={@writable} target={@composer_target} draft={@draft} overlay={@delivery_overlay} listener={@composer_listener} />
    </section>
    """
  end
end
