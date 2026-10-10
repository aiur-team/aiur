defmodule Aiur.BrowserHarness.UnitsLive do
  use Phoenix.LiveView, layout: {Aiur.BrowserHarness.FixtureLayout, :app}

  import Aiur.BrowserHarness.UnitsLive.Data

  alias Aiur.BrowserHarness.FixtureServer
  alias Aiur.TrackerIdentity

  alias AiurWeb.OperatorControlCenter.{
    AddAgentModal,
    ConversationDrawer,
    TicketContext,
    TicketDetailModal,
    TicketsPanel,
    TicketsPresenter,
    UnitsFilters,
    UnitsPresenter,
    UnitsTable,
    UnitsURL
  }

  alias AiurWeb.OperatorControlCenter.ConversationDrawer.Presenter, as: ConversationPresenter

  @now ~U[2026-07-17 12:00:00Z]

  @impl true
  # `?catalog=empty` mounts the same page with no units at all, so the browser
  # suite can look at the zero-unit catalog without first deleting every row.
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:writable, AiurWeb.Endpoint.config(:dashboard_writable) == true)
     |> assign(:catalog, mount_catalog(params))
     |> assign(:selection, UnitsURL.default_selection())
     |> assign(:now, @now)
     |> assign(:context, nil)
     |> assign(:conversation_drawer, nil)
     |> assign(:drafts, %{})
     |> assign(:sent_message, nil)
     |> assign(:selected_row, nil)
     |> assign(:tickets_view, tickets_view())
     # Deliberately below the production batch size: it puts a real reveal
     # control on a two-ticket fixture, so the browser exercises the button
     # without growing the shared Units fixture (extra rows destabilise the
     # unrelated filter and drawer specs on this page).
     |> assign(:tickets_visible, 1)
     |> assign(:tickets_query, "")
     |> assign(:tickets_panel_view, TicketsPresenter.search(tickets_view(), ""))
     |> assign(:ticket_detail, nil)
     |> assign(:add_agent_modal, nil)
     |> assign(:generation, 1)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :selection, UnitsURL.decode(params))}
  end

  @impl true
  def handle_event("select-units-scope", %{"scope" => scope}, socket) do
    selection = UnitsPresenter.select_scope(socket.assigns.selection, scope)
    {:noreply, push_patch(socket, to: units_path(selection))}
  end

  def handle_event("toggle-units-condition", %{"condition" => condition}, socket) do
    selection = UnitsPresenter.toggle_condition(socket.assigns.selection, condition)
    {:noreply, push_patch(socket, to: units_path(selection))}
  end

  def handle_event("select-all-units-filters", _params, socket) do
    {:noreply, push_patch(socket, to: units_path(UnitsPresenter.select_all_filters()))}
  end

  def handle_event("select-no-units-filters", _params, socket) do
    {:noreply, push_patch(socket, to: units_path(UnitsPresenter.select_no_filters()))}
  end

  def handle_event("reset-units-filters", _params, socket) do
    {:noreply, push_patch(socket, to: units_path(UnitsURL.zero_result_reset()))}
  end

  def handle_event("table-sort-changed", _params, socket), do: {:noreply, socket}

  def handle_event("inspect-unit", %{"unit" => token}, socket) do
    case UnitsPresenter.lookup(socket.assigns.catalog, token) do
      {:ok, row} -> {:noreply, socket |> assign(:selected_row, row) |> assign(:context, context(row))}
      {:error, :not_found} -> {:noreply, socket}
    end
  end

  def handle_event("inspect-ticket", %{"ticket" => token}, socket) do
    case TicketsPresenter.lookup(socket.assigns.tickets_view, token) do
      {:ok, row} -> {:noreply, assign(socket, :ticket_detail, row)}
      {:error, :not_found} -> {:noreply, socket}
    end
  end

  def handle_event("close-ticket-detail", _params, socket), do: {:noreply, assign(socket, :ticket_detail, nil)}

  def handle_event("show-more-tickets", _params, socket) do
    {:noreply, assign(socket, :tickets_visible, TicketsPresenter.reveal_more(socket.assigns.tickets_visible))}
  end

  def handle_event("search-tickets", %{"query" => query}, socket), do: {:noreply, search_tickets(socket, query)}

  def handle_event("clear-ticket-search", _params, socket), do: {:noreply, search_tickets(socket, "")}

  def handle_event("open-add-agent", %{"ticket" => token}, socket) do
    if socket.assigns.writable and AiurWeb.Endpoint.config(:dashboard_writable) == true do
      case TicketsPresenter.lookup(socket.assigns.tickets_view, token) do
        {:ok, row} -> {:noreply, assign(socket, :add_agent_modal, add_agent_modal(row))}
        {:error, :not_found} -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("close-add-agent", _params, socket), do: {:noreply, assign(socket, :add_agent_modal, nil)}

  def handle_event("change-add-agent", _params, socket), do: {:noreply, socket}

  def handle_event("confirm-add-agent", _params, socket), do: {:noreply, socket}

  def handle_event("show-agent-log", _params, socket), do: {:noreply, socket}

  def handle_event("read-conversation", %{"unit" => token}, socket) do
    case UnitsPresenter.lookup(socket.assigns.catalog, token) do
      {:ok, row} ->
        drawer = %{
          origin_id: "units-conversation-#{token}",
          row: row,
          view: ConversationPresenter.present(row, conversation_snapshot())
        }

        {:noreply, assign(socket, :conversation_drawer, drawer)}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  def handle_event("close-conversation", _params, socket), do: {:noreply, assign(socket, :conversation_drawer, nil)}

  def handle_event("composer-change", %{"message" => message}, socket) do
    {:noreply, assign(socket, :drafts, %{"1110" => message})}
  end

  def handle_event("send-operator-message", %{"message" => message}, socket) do
    Process.send_after(self(), :fixture_agent_voice_partial, 50)

    {:noreply, socket |> assign(:sent_message, message) |> assign(:drafts, %{"1110" => ""})}
  end

  def handle_event("pause-agent", _params, socket), do: {:noreply, socket}

  def handle_event("close-ticket-context", _params, socket) do
    {:noreply, socket |> assign(:context, nil) |> assign(:selected_row, nil)}
  end

  def handle_event("same-identity-update", _params, socket) do
    catalog = update_catalog(socket.assigns.catalog, &update_primary_row/1)

    {:noreply,
     socket
     |> assign(:catalog, catalog)
     |> update(:generation, &(&1 + 1))}
  end

  def handle_event("remove-selected-unit", _params, socket) do
    selected = socket.assigns.selected_row

    catalog =
      update_catalog(socket.assigns.catalog, fn rows ->
        Enum.reject(rows, &same_identity?(Map.get(&1, :identity), selected && selected.identity))
      end)

    projected_ids =
      catalog
      |> UnitsPresenter.project(socket.assigns.selection)
      |> Map.get(:rows, [])
      |> Enum.map(& &1.identity.identifier)

    FixtureServer.set_streamdeck_snapshot_identities(projected_ids)
    Phoenix.PubSub.broadcast(Aiur.PubSub, "streamdeck:fixture", :streamdeck_fixture_fleet_changed)

    {:noreply,
     socket
     |> assign(:catalog, catalog)
     |> update(:generation, &(&1 + 1))}
  end

  @impl true
  def handle_info(:fixture_agent_voice_partial, %{assigns: %{conversation_drawer: %{row: row} = drawer}} = socket) do
    updated_drawer = %{drawer | view: ConversationPresenter.present(row, conversation_snapshot(:with_partial_reply))}
    Process.send_after(self(), :fixture_agent_voice_reply, 250)
    {:noreply, assign(socket, :conversation_drawer, updated_drawer)}
  end

  def handle_info(:fixture_agent_voice_partial, socket), do: {:noreply, socket}

  def handle_info(:fixture_agent_voice_reply, %{assigns: %{conversation_drawer: %{row: row} = drawer}} = socket) do
    updated_drawer = %{drawer | view: ConversationPresenter.present(row, conversation_snapshot(:with_reply))}
    {:noreply, assign(socket, :conversation_drawer, updated_drawer)}
  end

  def handle_info(:fixture_agent_voice_reply, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    view = UnitsPresenter.project(assigns.catalog, assigns.selection)

    assigns =
      assigns
      |> assign(:view, view)
      |> assign(:announcement, UnitsPresenter.announcement(view))

    ~H"""
    <main class="app-shell" data-units-fixture="true" data-sent-message={@sent_message || ""}>
      <section class="section-card units-card" aria-labelledby="units-title">
        <header class="section-header units-header">
          <div>
            <p class="section-eyebrow">Current-run catalog</p>
            <h1 id="units-title" tabindex="-1">Units</h1>
            <p>{@view.total_count} observed · {@view.counts.scope} in selected scope</p>
          </div>
        </header>

        <p id="units-status" class="sr-only" role="status" aria-live="polite" aria-atomic="true">
          {@announcement}
        </p>

        <UnitsFilters.units_filters
          selection={@selection}
          counts={@view.counts}
          count_status={@view.count_status}
        />
        <UnitsTable.units_table view={@view} now={@now} />
      </section>

      <TicketsPanel.tickets_panel view={@tickets_panel_view} visible={@tickets_visible} writable={@writable} />

      <TicketDetailModal.ticket_detail_modal ticket={@ticket_detail} />
      <AddAgentModal.add_agent_modal modal={@add_agent_modal} writable={@writable} />

      <div class="controls" aria-label="Units fixture updates">
        <button id="same-identity-update" type="button" phx-click="same-identity-update">Update same Unit</button>
        <button id="remove-selected-unit" type="button" phx-click="remove-selected-unit">Remove selected Unit</button>
      </div>

      <TicketContext.ticket_context
        :if={@context}
        id="units-fixture-ticket-context"
        context={@context}
        close_event="close-ticket-context"
        fallback_focus_id="units-title"
      />

      <ConversationDrawer.conversation_drawer
        :if={@conversation_drawer}
        id="units-fixture-conversation-drawer"
        view={@conversation_drawer.view}
        composer={%{target_key: "1110", writable_target?: true, messages: []}}
        writable={true}
        drafts={@drafts}
        close_event="close-conversation"
        fallback_focus_id="units-title"
        origin_id={@conversation_drawer.origin_id}
      />
    </main>
    """
  end

  defp search_tickets(socket, query) do
    socket
    |> assign(:tickets_query, query)
    |> assign(:tickets_panel_view, TicketsPresenter.search(socket.assigns.tickets_view, query))
  end

  defp units_path(selection), do: "/units?" <> UnitsURL.encode(selection)

  defp same_identity?(%TrackerIdentity{} = left, %TrackerIdentity{} = right),
    do: TrackerIdentity.github_key(left) == TrackerIdentity.github_key(right)

  defp same_identity?(_left, _right), do: false
end
