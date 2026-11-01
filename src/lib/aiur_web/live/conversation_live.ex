defmodule AiurWeb.ConversationLive do
  @moduledoc "Paged durable conversation with a bounded live chronology and listener-mode composer."
  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}
  alias Aiur.Conversation.Ref
  alias AiurWeb.Conversation.{CommandCards, Commands, Components, Composer, ComposerEvents, EventComponents, Navigation, Paging, Presenter}

  @decision_events AiurWeb.OperatorControlCenter.DecisionEvents.events()

  @impl true
  def mount(%{"conversation_id" => id}, session, socket) do
    principal = AiurWeb.Conversation.Access.principal(session, socket)

    socket =
      socket
      |> assign(
        id: id,
        executor?: id == Ref.conversation_id(Ref.executor()),
        principal: principal,
        can_reveal: AiurWeb.Conversation.Access.can_reveal?(principal),
        state: :loading,
        page: nil,
        positions: [],
        revealed_positions: MapSet.new(),
        live_head: 0,
        sessions: [],
        last_entry: nil,
        read_error: nil,
        degraded: false,
        at_bottom: true,
        new_below: 0,
        reason: nil,
        mode: :tail,
        highlight_pos: nil,
        age: Presenter.age(nil, DateTime.utc_now())
      )
      |> stream_configure(:entries, dom_id: &"entry-#{&1.pos}")
      |> stream(:entries, [])
      |> ComposerEvents.init()
      |> Navigation.init()
      |> Commands.init()

    if connected?(socket) do
      Process.send_after(self(), :age_tick, 30_000)
      {:ok, socket |> Paging.subscribe() |> Navigation.load() |> Commands.subscribe()}
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

  def handle_event("jump_command", %{"id" => id}, socket) do
    case socket.assigns.command_slots[id] do
      {:at_pos, pos} ->
        socket = Paging.load(socket, {:around, pos})
        socket = if is_nil(socket.assigns.read_error), do: socket |> assign(:highlight_pos, pos) |> push_event("conversation-jump", %{}), else: socket
        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("draft", %{"text" => text}, socket), do: {:noreply, ComposerEvents.draft(socket, text)}
  def handle_event("send", %{"text" => text}, socket), do: {:noreply, ComposerEvents.send_message(socket, text)}

  def handle_event(event, params, socket) when event in @decision_events, do: {:noreply, Commands.handle(event, params, socket)}

  def handle_event("at_bottom", %{"value" => bottom}, socket) when is_boolean(bottom) do
    {:noreply, assign(socket, at_bottom: bottom, new_below: if(bottom, do: 0, else: socket.assigns.new_below))}
  end

  @impl true
  def handle_info({:entries_appended, id, entries}, %{assigns: %{id: id}} = socket),
    do: {:noreply, socket |> ComposerEvents.reconcile(entries) |> Paging.append(entries) |> Navigation.retry()}

  def handle_info({:anchor_added, id, anchor}, %{assigns: %{id: id}} = socket), do: {:noreply, socket |> Navigation.added(anchor) |> Commands.reload()}

  def handle_info({:decision_changed, _id, _version}, socket), do: {:noreply, socket |> Commands.reload()}
  def handle_info(:decision_metrics_changed, socket), do: {:noreply, socket}

  def handle_info(:delivery_tick, socket), do: {:noreply, ComposerEvents.poll(socket)}

  def handle_info({:session_changed, id, _session}, %{assigns: %{id: id}} = socket) do
    {:noreply, Paging.refresh_sessions(socket)}
  end

  def handle_info({:journal_degraded, id, degraded}, %{assigns: %{id: id}} = socket) do
    {:noreply, socket |> assign(:degraded, degraded) |> Paging.present()}
  end

  def handle_info(:age_tick, socket) do
    Process.send_after(self(), :age_tick, 30_000)
    {:noreply, socket |> Paging.present() |> ComposerEvents.refresh_mode() |> Commands.reload()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id="conversation" class="conversation-page">
      <a href="/">Build</a>
      <Components.status state={@state} age={@age} reason={@reason} last_entry={@last_entry} />
      <div :if={@state == :loading} role="status" aria-busy="true" class="conversation-skeleton">Loading conversation…</div>
      <p :if={@page && not @page.complete_from_start} role="note">Earlier history is not available</p>
      <nav :if={@page} aria-label="Conversation paging">
        <button phx-click="jump_start">Jump to start</button>
        <button :if={List.first(@positions, 1) > 1} phx-click="load_older" phx-disable-with="Loading older…">Load older</button>
        <button :if={List.last(@positions, 0) < @page.head_pos} phx-click="load_newer" phx-disable-with="Loading newer…">Load newer</button>
        <button phx-click="jump_latest">Latest entries</button>
      </nav>
      <p :if={@commands_error} role="status">{@commands_error} <a href="/commands">Commands</a></p>
      <nav aria-label="Conversation Commands">
        <button :for={row <- @decision_page.decisions} :if={match?({:at_pos, _}, @command_slots[row.decision_id])} phx-click="jump_command" phx-value-id={row.decision_id}>{row.question}</button>
      </nav>
      <CommandCards.cards rows={@decision_page.decisions} slots={@command_slots} actions={@decision_actions} writable={@writable} slot={:pinned_top} />
      <p :if={@position_notice} id="conversation-position-notice" role="status">{@position_notice}</p>
      <div class="conversation-layout">
        <EventComponents.event_nav streams={@streams} id={@id} visible_kinds={@visible_kinds} event_start={@event_start} event_has_newer={@event_has_newer} error={@anchor_error} />
        <div id="conversation-scroll" phx-hook="ConversationScroll" class="conversation-scroll" data-highlight={@highlight_pos} data-mode={if is_tuple(@mode), do: "around", else: @mode} data-head={@page && @page.head_pos}>
          <div id="conversation-entries" phx-update="stream">
            <div :for={{id, entry} <- @streams.entries} id={id}
              class={@highlight_pos == entry.pos && Navigation.highlight?(@anchors, entry.pos, @jump_placement) && "conversation-highlight"}
              aria-current={if @highlight_pos == entry.pos && Navigation.highlight?(@anchors, entry.pos, @jump_placement), do: "location"}
              data-jump-target={to_string(@highlight_pos == entry.pos && Navigation.highlight?(@anchors, entry.pos, @jump_placement))} >
              <Components.session_divider :for={session <- @sessions} :if={@executor? && entry.kind == "reasoning" && session.first_pos == entry.pos} session={session} />
              <Components.entry :if={not @executor? or entry.kind != "reasoning"} entry={entry} sessions={@sessions} can_reveal={@can_reveal} />
              <CommandCards.cards rows={@decision_page.decisions} slots={@command_slots} actions={@decision_actions} writable={@writable} slot={{:at_pos, entry.pos}} />
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
