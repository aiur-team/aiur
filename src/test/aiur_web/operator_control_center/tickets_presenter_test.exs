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

  test "a stale listing keeps its retained rows without staleness text" do
    view = TicketsPresenter.load(tickets_fun: fn -> snapshot(:stale, [ticket("41")]) end)

    assert view.status == :stale
    assert view.message =~ "Open tickets are shown below"
    refute view.message =~ "last saw"
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

  describe "search/2" do
    test "narrows the projection to matching tickets and counts the match against the backlog" do
      view = searchable_view()

      searched = TicketsPresenter.search(view, "storm")

      assert Enum.map(searched.rows, & &1.identifier) == ["43"]
      assert searched.query == "storm"
      assert searched.search_status == :matched
      assert searched.match_count == 1
      # The backlog did not shrink just because the operator typed.
      assert searched.total_count == 3
      assert TicketsPresenter.count_label(searched) == "1 of 3 tickets"
    end

    test "matches descriptions, not only titles" do
      view = searchable_view()

      assert [%{identifier: "43"}] = TicketsPresenter.search(view, "webhooks").rows
    end

    test "a query that matches nothing is its own state, distinct from an empty backlog" do
      searched = TicketsPresenter.search(searchable_view(), "zzzzqqqq")

      assert searched.rows == []
      assert searched.status == :ready
      assert searched.search_status == :no_matches
      assert searched.search_message == "No tickets match “zzzzqqqq”."
      assert TicketsPresenter.count_label(searched) == "0 of 3 tickets"
    end

    test "a stale listing that is searched is still reported as stale" do
      view = TicketsPresenter.load(tickets_fun: fn -> snapshot(:stale, [ticket("41")]) end)

      searched = TicketsPresenter.search(view, "zzzzqqqq")

      assert searched.status == :stale
      assert searched.message =~ "Open tickets are shown below"
      assert searched.search_status == :no_matches
    end

    test "clearing the query restores the full list without a provider read" do
      view = searchable_view()

      restored = TicketsPresenter.search(view, "")

      assert restored.rows == view.rows
      assert restored.query == ""
      assert restored.search_status == :inactive
      assert TicketsPresenter.count_label(restored) == "3 tickets"
    end

    test "a whitespace-only query is not a search" do
      assert TicketsPresenter.search(searchable_view(), "   ").search_status == :inactive
    end

    test "the announcement states the result so filtering is not silent to a screen reader" do
      view = searchable_view()

      # An untouched panel says nothing: this region sits beside the fleet's own
      # status region and the backlog polls on its own schedule.
      assert TicketsPresenter.search_announcement(view) == ""
      assert TicketsPresenter.search_announcement(TicketsPresenter.search(view, "storm")) == "1 of 3 tickets match."

      assert TicketsPresenter.search_announcement(TicketsPresenter.search(view, "zzzzqqqq")) ==
               "No tickets match “zzzzqqqq”."
    end

    test "the query is echoed back exactly as typed, so a trailing space survives the round trip" do
      searched = TicketsPresenter.search(searchable_view(), "storm ")

      assert searched.query == "storm "
      assert searched.match_count == 1
    end

    test "searching an already-searched view narrows the backlog, not the previous result" do
      view = searchable_view()

      once = TicketsPresenter.search(view, "storm")
      twice = TicketsPresenter.search(once, "documentation")

      # "documentation" misses the "storm" result, so a view that filtered its
      # own output would report no matches for a ticket that plainly exists.
      assert twice.match_count == 0
      assert twice.total_count == 3
      assert TicketsPresenter.search(once, "").rows == view.rows
    end

    test "a listing with nothing in it reports no search state for a query that outlived it" do
      empty = TicketsPresenter.load(tickets_fun: fn -> snapshot(:available, []) end)

      searched = TicketsPresenter.search(empty, "storm")

      # Otherwise the panel states "no open tickets" and "no tickets match" at
      # once, with no control left to clear the query.
      assert searched.search_status == :inactive
      assert searched.status == :empty
      assert TicketsPresenter.count_label(searched) == "0 tickets"
    end

    test "a truncated listing does not claim a match is absent from tickets it never listed" do
      snapshot = %{snapshot(:available, [ticket("41"), ticket("42")]) | truncated?: true}
      view = TicketsPresenter.load(tickets_fun: fn -> snapshot end)

      searched = TicketsPresenter.search(view, "zzzzqqqq")

      assert searched.search_message == "No match for “zzzzqqqq” in the first 2 tickets listed."
    end

    test "a truncated listing stays a lower bound while a search is active" do
      snapshot = %{snapshot(:available, [ticket("41"), ticket("42")]) | truncated?: true}
      view = TicketsPresenter.load(tickets_fun: fn -> snapshot end)

      assert TicketsPresenter.count_label(TicketsPresenter.search(view, "41")) == "1 of at least 2 tickets"
    end
  end

  defp searchable_view do
    tickets = [
      ticket("41"),
      ticket("42"),
      %{ticket("43") | title: "Retry the dispatch", body_excerpt: "A storm of webhooks overwhelms the poller."}
    ]

    TicketsPresenter.load(tickets_fun: fn -> snapshot(:available, tickets) end)
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
      body_excerpt: nil,
      url: "https://github.com/its-everdred/aiur/issues/#{identifier}",
      state: "Todo",
      labels: labels,
      assignee: nil,
      created_at: ~U[2026-07-16 12:00:00Z],
      updated_at: ~U[2026-07-17 11:00:00Z]
    }
  end
end
