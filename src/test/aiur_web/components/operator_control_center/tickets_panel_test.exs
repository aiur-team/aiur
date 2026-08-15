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
