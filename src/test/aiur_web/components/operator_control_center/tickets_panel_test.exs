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
  end

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
