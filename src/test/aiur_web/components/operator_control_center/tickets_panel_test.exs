defmodule AiurWeb.OperatorControlCenter.TicketsPanelTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Aiur.OpenTicketSource.Snapshot
  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.{TicketsPanel, TicketsPresenter}

  test "renders the panel header, one row per ticket, and a robot add-agent action" do
    view = view(:available, [ticket("41", ["agent:todo", "complexity:3"]), ticket("42")])
    [first, _second] = view.rows

    html = render_component(&TicketsPanel.tickets_panel/1, %{view: view})

    assert html =~ ~s(<span class="rs-group-title" id="tickets-title">Tickets</span>)
    assert html =~ ~s(<span class="rs-group-count">2 tickets</span>)
    assert html =~ ~s(id="ticket-#{first.token}")
    assert html =~ ~s(phx-click="inspect-ticket")
    assert html =~ "agent:todo"
    assert html =~ "complexity:3"

    # The action column is the only cell that does not open the detail modal.
    assert html =~ ~s(phx-click="open-add-agent")
    assert html =~ ~s(title="Add an agent")
    assert html =~ "<svg"
  end

  # The routing prediction is a decision the operator makes in the add-agent
  # modal, where it is editable, not a column they can only read.
  test "the table does not carry a routing column" do
    html = render_component(&TicketsPanel.tickets_panel/1, %{view: view(:available, [ticket("41", ["complexity:3"])])})

    # Anchor the refutations to a rendered row table, so a regression that dropped
    # the table entirely cannot read as "the column is correctly gone".
    assert html =~ "tickets-rows"
    assert html =~ ~s(<th class="tk-col-title">Title</th>)

    refute html =~ "Would route to"
    refute html =~ "tk-col-agent"
    refute html =~ "tk-agent-cell"
  end

  test "an empty listing states it instead of rendering a headerless blank table" do
    html = render_component(&TicketsPanel.tickets_panel/1, %{view: view(:available, [])})

    assert html =~ "No open tickets on this repository."
    assert html =~ ~s(<span class="rs-group-count">0 tickets</span>)
    refute html =~ "tickets-rows"
    # Nothing is hidden at zero tickets, so there is no reveal control to press.
    refute html =~ "show-more-tickets"
  end

  test "a long listing opens on the first batch and offers to reveal the rest" do
    view = view(:available, tickets(23))

    html = render_component(&TicketsPanel.tickets_panel/1, %{view: view})

    assert rendered_row_tokens(html, view) == Enum.map(Enum.take(view.rows, 5), & &1.token)
    # Hidden rows never reach the client; the reveal is server-side, not CSS.
    refute html =~ ~s(id="ticket-#{Enum.at(view.rows, 5).token}")

    assert html =~ ~s(<div class="tickets-more">)
    assert html =~ ~s(phx-click="show-more-tickets")
    assert html =~ ~s(<button type="button" class="btn ghost")
    assert html =~ "Show 10 more tickets"
  end

  test "revealing keeps the rows already shown and adds the next batch" do
    view = view(:available, tickets(23))

    html = render_component(&TicketsPanel.tickets_panel/1, %{view: view, visible: TicketsPresenter.reveal_more(5)})

    assert rendered_row_tokens(html, view) == Enum.map(Enum.take(view.rows, 15), & &1.token)
    # The remainder is smaller than a full step, so the control names what is left.
    assert html =~ "Show 8 more tickets"
  end

  test "the reveal control disappears once every ticket is shown" do
    view = view(:available, tickets(5))

    html = render_component(&TicketsPanel.tickets_panel/1, %{view: view})

    assert length(rendered_row_tokens(html, view)) == 5
    refute html =~ "tickets-more"
    refute html =~ "show-more-tickets"
  end

  test "one remaining ticket reads as a singular reveal" do
    view = view(:available, tickets(6))

    html = render_component(&TicketsPanel.tickets_panel/1, %{view: view})

    assert html =~ "Show 1 more ticket<"
  end

  defp rendered_row_tokens(html, view) do
    Enum.filter(Enum.map(view.rows, & &1.token), &(html =~ ~s(id="ticket-#{&1}")))
  end

  defp tickets(count), do: Enum.map(1..count, &ticket(to_string(&1)))

  test "an unavailable listing names itself rather than reading as zero tickets" do
    html = render_component(&TicketsPanel.tickets_panel/1, %{view: TicketsPresenter.normalize(nil)})

    assert html =~ "Open tickets are unavailable."
    assert html =~ "tickets unavailable"
  end

  test "the search input sits under the title, is labelled, and is debounced rather than per-keystroke" do
    html = render_component(&TicketsPanel.tickets_panel/1, %{view: view(:available, [ticket("41")])})

    assert html =~ ~s(<label class="sr-only" for="tickets-search">Search tickets by title, description, or ID</label>)
    assert html =~ ~s(type="search")
    assert html =~ ~s(name="query")
    assert html =~ ~s(phx-change="search-tickets")
    assert html =~ ~s(phx-debounce="150")
    # Submitting must not reload the page out from under the LiveView.
    assert html =~ ~s(phx-submit="search-tickets")

    # The title is announced before the control that narrows it.
    assert :binary.match(html, "tickets-title") < :binary.match(html, "tickets-search")
  end

  test "an active search shows the matched count, a clear control, and announces the result" do
    view = TicketsPresenter.search(view(:available, [ticket("41"), ticket("42")]), "41")

    html = render_component(&TicketsPanel.tickets_panel/1, %{view: view})

    assert html =~ ~s(value="41")
    assert html =~ ~s(<span class="rs-group-count">1 of 2 tickets</span>)
    assert html =~ ~s(phx-click="clear-ticket-search")
    assert html =~ "1 of 2 tickets match."
  end

  test "a search with no matches states so instead of rendering an empty panel" do
    view = TicketsPresenter.search(view(:available, [ticket("41")]), "zzzzqqqq")

    html = render_component(&TicketsPanel.tickets_panel/1, %{view: view})

    assert html =~ "No tickets match"
    assert html =~ "tk-no-matches"
    # The input keeps the query so the operator can edit it rather than retype,
    # and the control that clears it is still there to get back out.
    assert html =~ ~s(value="zzzzqqqq")
    assert html =~ ~s(phx-click="clear-ticket-search")
    refute html =~ "tickets-rows"
  end

  # Both statements at once would be nonsense, and with the form hidden the
  # operator would have no control left to clear the query that caused it.
  test "a query that outlives its listing does not add 'no matches' to an unavailable panel" do
    view = TicketsPresenter.search(TicketsPresenter.normalize(nil), "zzzzqqqq")

    html = render_component(&TicketsPanel.tickets_panel/1, %{view: view})

    assert html =~ "Open tickets are unavailable."
    refute html =~ "No tickets match"
    refute html =~ ~s(id="tickets-search")
  end

  test "a listing with no tickets to search does not render a search control" do
    html = render_component(&TicketsPanel.tickets_panel/1, %{view: view(:available, [])})

    refute html =~ ~s(id="tickets-search")
  end

  # At zero tickets the panel's own empty state is the whole story: a second
  # message about a query, or a control offering to reveal nothing, would be
  # two answers to a question the operator did not ask twice.
  test "an empty backlog states itself once, with no search message and nothing to reveal" do
    html = render_component(&TicketsPanel.tickets_panel/1, %{view: view(:available, [])})

    assert html =~ "No open tickets on this repository."
    refute html =~ "No tickets match"
    refute html =~ "tk-no-matches"
    refute html =~ "show-more-tickets"
  end

  # The Units table's own dashed empty state says "No live units." That sentence
  # is about the fleet, not about a filtered ticket list, and this panel must
  # neither borrow it nor render nothing in its place.
  test "a search with no matches speaks for itself rather than borrowing the Units empty state" do
    view = TicketsPresenter.search(view(:available, [ticket("41"), ticket("42")]), "zzzzqqqq")

    html = render_component(&TicketsPanel.tickets_panel/1, %{view: view})

    assert html =~ "No tickets match “zzzzqqqq”."
    refute html =~ "No live units."
    # Not silence: the panel renders a stated reason where the table was.
    assert html =~ "tk-no-matches"
    refute html =~ "show-more-tickets"
  end

  defp view(status, tickets) do
    TicketsPresenter.project(%Snapshot{status: status, generation: 1, observed_at: ~U[2026-07-17 12:00:00Z], tickets: tickets})
  end

  defp ticket(identifier, labels \\ []) do
    %{
      identity: %TrackerIdentity{
        status: :joinable,
        kind: :github,
        owner: "acme",
        repository: "aiur",
        provider_id: "NODE-#{identifier}",
        identifier: identifier,
        reason: nil
      },
      identifier: identifier,
      title: "Ticket #{identifier}",
      url: "https://github.com/acme/aiur/issues/#{identifier}",
      state: "Todo",
      labels: labels,
      assignee: nil,
      created_at: ~U[2026-07-16 12:00:00Z],
      updated_at: ~U[2026-07-17 11:00:00Z]
    }
  end
end
