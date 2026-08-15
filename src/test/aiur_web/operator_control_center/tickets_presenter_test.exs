defmodule AiurWeb.OperatorControlCenter.TicketsPresenterTest do
  use ExUnit.Case, async: true

  alias Aiur.OpenTicketSource.Snapshot
  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.TicketsPresenter

  test "projects open tickets into rows with stable lookup tokens" do
    view = TicketsPresenter.load(tickets_fun: fn -> snapshot(:available, [ticket("41"), ticket("42")]) end)

    assert view.status == :ready
    assert view.total_count == 2
    assert [first, second] = view.rows
    assert first.identifier == "41"
    assert first.token != second.token
    assert {:ok, ^second} = TicketsPresenter.lookup(view, second.token)
    assert TicketsPresenter.lookup(view, "unknown-token") == {:error, :not_found}
  end

  test "the reveal opens on a glance-sized batch and widens once the operator asks for more" do
    assert TicketsPresenter.initial_reveal() == 5

    # 5 -> 15 -> 25: the second step is wider, so a busy backlog is two presses
    # away rather than four.
    assert TicketsPresenter.reveal_more(5) == 15
    assert TicketsPresenter.reveal_more(15) == 25

    # Any count below the opening batch — or a value the panel never produces —
    # reveals the opening batch rather than a partial or negative window.
    assert TicketsPresenter.reveal_more(1) == 5
    assert TicketsPresenter.reveal_more(0) == 5
    assert TicketsPresenter.reveal_more(nil) == 5
  end

  test "an empty available listing is named empty, never unavailable" do
    view = TicketsPresenter.load(tickets_fun: fn -> snapshot(:available, []) end)

    assert view.status == :empty
    assert view.message == "No open tickets on this repository."
    assert TicketsPresenter.count_label(view) == "0 tickets"
  end

  test "a stale listing keeps its retained rows and says why" do
    view = TicketsPresenter.load(tickets_fun: fn -> snapshot(:stale, [ticket("41")]) end)

    assert view.status == :stale
    assert view.message =~ "last-known-good"
    assert length(view.rows) == 1
  end

  test "an unreadable provider is unavailable rather than an empty healthy table" do
    view = TicketsPresenter.load(tickets_fun: fn -> raise "provider down" end)

    assert view.status == :unavailable
    assert view.rows == []
    assert TicketsPresenter.count_label(view) == "tickets unavailable"
  end

  test "normalize passes an already-projected view through and rejects anything else" do
    view = TicketsPresenter.load(tickets_fun: fn -> snapshot(:available, [ticket("41")]) end)

    assert TicketsPresenter.normalize(view) == view
    assert TicketsPresenter.normalize(nil).status == :unavailable
  end

  test "a non-GitHub tracker is unsupported, not an outage" do
    view = TicketsPresenter.load(tickets_fun: fn -> snapshot(:unsupported, []) end)

    assert view.status == :unsupported
    assert view.message == "Open tickets are listed for GitHub trackers only."
    assert TicketsPresenter.count_label(view) == "not a GitHub tracker"
  end

  test "a truncated listing is qualified as a lower bound" do
    snapshot = %{snapshot(:available, [ticket("41")]) | truncated?: true}
    view = TicketsPresenter.load(tickets_fun: fn -> snapshot end)

    assert TicketsPresenter.count_label(view) == "at least 1 ticket"
  end

  # A row with no token could neither be looked up nor carry a unique DOM id.
  test "tickets whose identity will not join are dropped rather than rendered dead" do
    unjoinable = %{ticket("41") | identity: nil}
    view = TicketsPresenter.load(tickets_fun: fn -> snapshot(:available, [unjoinable, ticket("42")]) end)

    assert Enum.map(view.rows, & &1.identifier) == ["42"]
    assert view.total_count == 1
  end

  test "each row carries the routing the ticket's labels would select" do
    view = TicketsPresenter.load(tickets_fun: fn -> snapshot(:available, [ticket("41", ["complexity:3"])]) end)

    assert [%{routing: routing}] = view.rows
    assert Map.has_key?(routing, :available?)
    assert Map.has_key?(routing, :backend)
  end

  defp snapshot(status, tickets) do
    %Snapshot{status: status, generation: 1, observed_at: ~U[2026-07-17 12:00:00Z], tickets: tickets}
  end

  defp ticket(identifier, labels \\ []) do
    %{
      identity: %TrackerIdentity{
        status: :joinable,
        kind: :github,
        owner: "its-everdred",
        repository: "aiur",
        provider_id: "NODE-#{identifier}",
        identifier: identifier,
        reason: nil
      },
      identifier: identifier,
      title: "Ticket #{identifier}",
      url: "https://github.com/its-everdred/aiur/issues/#{identifier}",
      state: "Todo",
      labels: labels,
      assignee: nil,
      created_at: ~U[2026-07-16 12:00:00Z],
      updated_at: ~U[2026-07-17 11:00:00Z]
    }
  end
end
