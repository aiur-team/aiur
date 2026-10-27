defmodule AiurWeb.Build.ConversationEventsTest do
  # The operator reads what happened to a ticket from these rows, so every
  # mapping must say only what a real source says: no invented percent, time,
  # dependency state or "by you".
  use ExUnit.Case, async: true

  alias AiurWeb.Build.ConversationEvents, as: Events

  @ts "2026-10-07T21:13:20.000000Z"
  @at 1_791_407_600_000
  @repo "aiur-team/aiur"

  defp line(id, suffix, summary \\ "", opts \\ []),
    do: %{kind: "self", id: id, topic: Keyword.get(opts, :topic, "ticket.12.agent." <> suffix), ts: Keyword.get(opts, :ts, @ts), summary: summary}

  defp facts(overrides \\ %{}), do: Map.merge(%{deps: %{}, merges: [], decisions: {:ok, []}, pause: nil, by_you_at: nil, repository: @repo}, overrides)
  defp row(overrides), do: Map.merge(%{"id" => "12", "num" => 12, "title" => "Ticket twelve", "deps" => [], "agent" => %{"state" => "active"}}, overrides)
  defp tail(row, facts \\ facts()), do: Events.current_facts(row, facts).tail

  describe "log rows" do
    test "E1 the eight mapped topics map per table and unmapped agent topics give nothing" do
      mapped = ~w(progress progress.checkin progress.phase phase.review.start phase.review.end blocked unblocked pause.request)
      unmapped = ~w(phase.work.end ci.unrelated-failure attention.resolved)
      rows = Enum.with_index(mapped ++ unmapped, &line(&2 + 1, &1))

      assert Events.from_log(rows, "12", %{}) |> Enum.map(&{&1.ev, &1.label}) == [
               {"prog", "Progress updated"},
               {"prog", "Progress updated"},
               {"prog", "Progress updated"},
               {"review", "Review started"},
               {"review", "Review complete"},
               {"dep", "Blocked"},
               {"dep", "Unblocked"},
               {"you", "Agent asked to pause"}
             ]
    end

    test "another ticket's topic is not this ticket's history" do
      assert Events.from_log([line(1, "blocked", "", topic: "ticket.99.agent.blocked"), line(2, "blocked", "", topic: "ticket.120.agent.blocked")], "12", %{}) == []
    end

    test "E3 a percent is joined by event id" do
      assert [%{ev: "prog", pct: 50, label: "Progress · 50%", sub: "Core done", id: "ev:log:41"}] = Events.from_log([line(41, "progress", "Core done")], "12", %{41 => 50})
    end

    test "E4/E5 an unknown percent is never zero and never another event's" do
      [entry] = Events.from_log([line(41, "progress", "Core done")], "12", %{40 => 75})
      assert entry.label == "Progress updated"
      refute Map.has_key?(entry, :pct)
      assert Events.progress_index({:error, %{kind: :configuration}}) == %{}
    end

    test "progress index reads only an available snapshot's progress entries" do
      snapshot = %{health: :available, entries: [%{kind: :progress, event_id: 40, details: %{percent: 75}}, %{kind: :phase, event_id: 39, details: %{}}]}
      assert Events.progress_index({:ok, snapshot}) == %{40 => 75}
      assert Events.progress_index({:ok, %{snapshot | health: :stale}}) == %{}
    end

    test "E6 the log ts becomes daemon epoch ms; E7 an unparseable ts drops the row" do
      assert [%{at: @at}] = Events.from_log([line(1, "blocked")], "12", %{})
      assert Events.from_log([line(1, "blocked", "", ts: "2026-13-99T99:00:00Z")], "12", %{}) == []
    end

    test "E15 markup stays raw text (the client escapes it)" do
      [entry] = Events.from_log([line(1, "blocked", "a & <b>x</b>")], "12", %{})
      assert entry.sub == "a & <b>x</b>"
    end

    test "an empty summary leaves sub out" do
      [entry] = Events.from_log([line(1, "blocked", "")], "12", %{})
      refute Map.has_key?(entry, :sub)
    end
  end

  describe "current facts" do
    test "E9 dependency rows say only the state the dependency row proves" do
      t = ~U[2026-10-07 21:13:20Z]

      deps = %{
        "1" => %{"id" => "1", "num" => 1, "title" => "A", "status" => "done", "pr" => %{"num" => 5, "state" => "merged"}},
        "2" => %{"id" => "2", "num" => 2, "title" => "B", "sec" => "now", "status" => "running"},
        "3" => %{"id" => "3", "num" => 3, "title" => "C", "status" => "done", "pr" => nil},
        "4" => %{"id" => "4", "num" => 4, "title" => "D", "status" => "mystery"}
      }

      merges = [%{ticket_id: "1", repository: "Aiur-Team/Aiur", number: 5, merged_at: t}]
      %{deps: rows} = Events.current_facts(row(%{"deps" => ~w(1 2 3 4 missing)}), facts(%{deps: deps, merges: merges}))

      assert Enum.map(rows, &{&1.label, &1.at, &1.go, &1[:sub]}) == [
               {"Dependency #1 merged", @at, "1", "A"},
               {"Dependency #2 in progress", nil, "2", "B"},
               {"Dependency #3 closed", nil, "3", "C"},
               {"Dependency #4 · state unknown", nil, "4", "D"}
             ]
    end

    test "E10 merge row time comes from the merge store, else the row end, else unknown; no PR, no row" do
      merge = %{ticket_id: "12", repository: @repo, number: 8, merged_at: ~U[2026-10-07 21:13:20Z]}
      assert [%{ev: "merge", label: "Merged PR #8", at: @at}] = tail(row(%{}), facts(%{merges: [merge]}))
      assert [%{ev: "merge", at: 99}] = tail(row(%{"pr" => %{"num" => 8, "state" => "merged"}, "end" => 99}))
      assert [%{ev: "merge", at: nil}] = tail(row(%{"pr" => %{"num" => 8, "state" => "merged"}, "end" => nil}), facts(%{merges: :unavailable}))
      assert tail(row(%{"pr" => nil})) == []
    end

    test "E11 a merge of another repository with the same ticket id is ignored" do
      merge = %{ticket_id: "12", repository: "other/repo", number: 8, merged_at: ~U[2026-10-07 21:13:20Z]}
      assert tail(row(%{}), facts(%{merges: [merge]})) == []
    end

    test "E22 an open PR reads like the design and has no invented time; a failed closed PR is a fail row" do
      assert [%{ev: "pr", label: "Opened PR #8", sub: "Ticket twelve", at: nil}] = tail(row(%{"pr" => %{"num" => 8, "state" => "open"}}))
      assert [%{ev: "fail", label: "PR #8 closed", id: "ev:fail:pr:8"}] = tail(row(%{"pr" => %{"num" => 8, "state" => "closed"}, "status" => "failed"}))
    end

    test "E12 state rows per agent state" do
      decision = %{id: "d1", ticket: %{identifier: "12", url: "https://github.com/aiur-team/aiur/issues/12"}, created_at: ~U[2026-10-07 21:13:20Z]}

      cases = [
        {"command", facts(%{decisions: {:ok, [decision]}}), {"cmd", "Asked a blocking question", @at}},
        {"command", facts(%{decisions: :unavailable}), {"cmd", "Asked a blocking question", nil}},
        {"paused", facts(%{pause: :operator_pause}), {"you", "Paused by you", nil}},
        {"parked", facts(%{pause: :usage_limit_exhausted}), {"you", "Parked · waiting for model capacity", nil}},
        {"parked", facts(%{pause: :github_budget_hold}), {"you", "Parked · GitHub budget hold", nil}},
        {"parked", facts(%{pause: :other}), {"you", "Parked", nil}},
        {"error", facts(), {"fail", "Error", nil}},
        {"retries", facts(), {"fail", "Retries exhausted", nil}}
      ]

      for {state, facts, expected} <- cases do
        assert [entry] = tail(row(%{"agent" => %{"state" => state}}), facts), state
        assert {entry.ev, entry.label, entry.at} == expected
      end
    end

    test "E13 no state row for an unknown or active agent" do
      assert tail(row(%{"agent" => %{"state" => nil}})) == []
      assert tail(row(%{"agent" => %{"state" => "active"}})) == []
    end

    test "E14 \"by you\" only for an operator pause" do
      labels = for pause <- [:operator_pause, :automatic_pause, :tracker_paused], do: hd(tail(row(%{"agent" => %{"state" => "paused"}}), facts(%{pause: pause}))).label
      assert labels == ["Paused by you", "Paused", "Paused"]
    end

    test "E20 a blocking decision naming another repository is not this ticket's question" do
      decision = %{id: "d1", ticket: %{identifier: "12", url: "https://github.com/other/repo/issues/12"}, created_at: ~U[2026-10-07 21:13:20Z]}
      assert tail(row(%{}), facts(%{decisions: {:ok, [decision]}})) == []
    end

    test "an open decision with no URL still counts" do
      decision = %{id: "d1", ticket: %{identifier: "12", url: nil}, created_at: ~U[2026-10-07 21:13:20Z]}
      assert [%{id: "ev:cmd:d1", sub: "waiting for your answer"}] = tail(row(%{}), facts(%{decisions: {:ok, [decision]}}))
    end

    test "resumed only from paused or parked to active, never \"by you\"" do
      assert %{ev: "commit", label: "Resumed", at: 5, id: "ev:resume:5"} = Events.resumed("paused", "active", 5)
      assert Events.resumed("parked", "active", 5).label == "Resumed"
      assert Events.resumed("active", "active", 5) == nil
      assert Events.resumed("paused", "error", 5) == nil
    end
  end

  describe "page placement" do
    defp ev(at), do: %{id: "ev:log:#{at}", k: "ev", ev: "prog", label: "L", at: at}
    defp en(at), do: %{id: "e#{at}", k: "say", at: at, text: "t"}
    defp ids(entries), do: Enum.map(entries, & &1.id)
    defp parts, do: %{lead: [%{id: "ev:dep:1", k: "ev", at: nil}], tail: [%{id: "ev:state:paused", k: "ev", at: nil}]}

    test "E16/E17 windows are contiguous, every event appears once, deps open only the oldest page" do
      log = Enum.map([3, 12, 15, 20, 25, 35], &ev/1)
      {first, upper} = Events.page([en(20), en(30)], log, :infinity, true, parts())
      assert ids(first) == ~w(e20 ev:log:20 ev:log:25 e30 ev:log:35 ev:state:paused)
      assert upper == 20

      {older, upper} = Events.page([en(5), en(10)], log, upper, false, %{parts() | tail: []})
      assert ids(older) == ~w(ev:dep:1 ev:log:3 e5 e10 ev:log:12 ev:log:15)
      assert upper == :none

      sent = Enum.filter(ids(first) ++ ids(older), &String.starts_with?(&1, "ev:log:"))
      assert Enum.sort(sent) == Enum.sort(ids(log))
    end

    test "E17b a page with no timed entry gets no events and keeps the bound for the next page" do
      log = [ev(3)]
      assert {[%{id: "e"}], 20} = Events.page([%{id: "e", k: "say", at: nil}], log, 20, true, %{lead: [], tail: []})
      assert {[%{id: "ev:log:3"}, %{id: "e5"}], :none} = Events.page([en(5)], log, 20, false, %{lead: [], tail: []})
    end

    test "a first view with no timed entry carries every event" do
      assert {[%{id: "e"}, %{id: "ev:log:3"}], :none} = Events.page([%{id: "e", k: "say", at: nil}], [ev(3)], :infinity, true, %{lead: [], tail: []})
    end

    test "ties order by log id after the entry" do
      log = [%{ev(7) | id: "ev:log:9"}, %{ev(7) | id: "ev:log:2"}]
      {entries, _} = Events.page([en(7)], log, :infinity, true, %{lead: [], tail: []})
      assert ids(entries) == ~w(e7 ev:log:2 ev:log:9)
    end

    test "live appends cover only the pages already sent" do
      assert Events.shown?(ev(25), 20)
      refute Events.shown?(ev(12), 20)
      assert Events.shown?(ev(12), :none)
    end
  end
end
