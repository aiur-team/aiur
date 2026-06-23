defmodule Aiur.Events.DebugLogTest do
  @moduledoc """
  #409 item 4 — per-identifier DebugLog subscription.

  Every SessionWriter used to subscribe the GLOBAL DebugLog topic and
  filter each mark in `handle_info`, so at high concurrency every
  cross-ticket mark was fanned to all ~M×N writers and discarded by all
  but one. The fix routes each mark to a per-identifier sub-topic so a
  writer only receives the marks that belong to its agent — preserving
  `EventRow.matches?/2` semantics exactly:

    * `:receive` / `:read` carry an explicit `identifier` → routed there.
    * `:publish` carries no identifier → routed by the `ticket.<id>.`
      prefix embedded in its topic (the agent's own published events).

  The global topic is retained for the AgentList debug ticker and the
  ChatCompletions live bridge.
  """

  use ExUnit.Case, async: false

  alias Aiur.Events.DebugLog
  alias Aiur.Opencode.EventRow

  test "per-identifier subscriber receives :publish marks for its own ticket topic" do
    DebugLog.subscribe("issue-1")

    DebugLog.broadcast(:publish, "ticket.issue-1.pr.opened", id: 1, body: %{title: "x"})

    assert_receive {:event_debug, %{kind: :publish, topic: "ticket.issue-1.pr.opened"}}, 500
  end

  test "per-identifier subscriber does NOT receive another ticket's :publish marks" do
    DebugLog.subscribe("issue-1")

    DebugLog.broadcast(:publish, "ticket.issue-2.pr.opened", id: 2, body: %{title: "y"})

    refute_receive {:event_debug, %{topic: "ticket.issue-2.pr.opened"}}, 200
  end

  test "per-identifier subscriber receives :receive/:read marks addressed to it by identifier" do
    DebugLog.subscribe("issue-1")

    DebugLog.broadcast(:receive, "ticket.issue-9.branch.push", id: 3, identifier: "issue-1")
    assert_receive {:event_debug, %{kind: :receive, identifier: "issue-1"}}, 500

    DebugLog.broadcast(:read, "ticket.issue-9.branch.push", id: 4, identifier: "issue-1")
    assert_receive {:event_debug, %{kind: :read, identifier: "issue-1"}}, 500
  end

  test "per-identifier subscriber does NOT receive marks addressed to another identifier" do
    DebugLog.subscribe("issue-1")

    DebugLog.broadcast(:receive, "ticket.issue-9.branch.push", id: 5, identifier: "issue-2")

    refute_receive {:event_debug, %{identifier: "issue-2"}}, 200
  end

  test "global subscriber still receives every mark (AgentList / ChatCompletions path)" do
    DebugLog.subscribe()

    DebugLog.broadcast(:publish, "ticket.issue-1.pr.opened", id: 6)
    DebugLog.broadcast(:receive, "ticket.issue-9.branch.push", id: 7, identifier: "issue-2")

    assert_receive {:event_debug, %{topic: "ticket.issue-1.pr.opened"}}, 500
    assert_receive {:event_debug, %{kind: :receive, identifier: "issue-2"}}, 500
  end

  # The per-identifier routing in DebugLog.broadcast and the in-handler
  # `EventRow.matches?/2` guard are duplicated logic bound only by a
  # comment. This pins their equivalence: a per-identifier subscriber
  # receives an entry IFF `matches?` would have accepted it — including
  # the non-`ticket.` topic case where neither should deliver.
  test "per-identifier delivery matches EventRow.matches?/2 for representative entries" do
    DebugLog.subscribe("issue-1")

    entries = [
      {%{kind: :publish, topic: "ticket.issue-1.pr.opened", identifier: nil}, true},
      {%{kind: :publish, topic: "ticket.issue-2.pr.opened", identifier: nil}, false},
      {%{kind: :receive, topic: "ticket.issue-9.branch.push", identifier: "issue-1"}, true},
      {%{kind: :receive, topic: "ticket.issue-1.branch.push", identifier: "issue-2"}, false},
      {%{kind: :publish, topic: "system.main.branch.push", identifier: nil}, false}
    ]

    for {{entry, expected}, idx} <- Enum.with_index(entries) do
      assert EventRow.matches?(entry, "issue-1") == expected,
             "matches?/2 baseline drifted for #{inspect(entry)}"

      DebugLog.broadcast(entry.kind, entry.topic, id: 100 + idx, identifier: entry.identifier, body: nil)

      if expected do
        topic = entry.topic
        assert_receive {:event_debug, %{topic: ^topic}}, 500
      end
    end

    # Negative cases must not have leaked onto issue-1's sub-topic. By
    # now the positive broadcasts above have been drained; anything left
    # matching a known-negative topic is a routing bug.
    refute_receive {:event_debug, %{topic: "ticket.issue-2.pr.opened"}}, 50
    refute_receive {:event_debug, %{topic: "ticket.issue-1.branch.push"}}, 50
    refute_receive {:event_debug, %{topic: "system.main.branch.push"}}, 50
  end

  # The fix only works if the consumer is wired to the per-identifier
  # topic. Guards the exact regression: reverting session_writer.ex to
  # the global `DebugLog.subscribe()` would re-open the M×N mailbox fan
  # while every behavioral test above (which subscribes a bare process)
  # still passes.
  test "SessionWriter subscribes per-identifier, not the global firehose" do
    source =
      Path.expand("../../../lib/aiur/opencode/session_writer.ex", __DIR__)
      |> File.read!()

    assert source =~ ~r/DebugLog\.subscribe\(state\.identifier\)/,
           "SessionWriter MUST subscribe its own DebugLog sub-topic (#409 item 4)"

    refute source =~ ~r/DebugLog\.subscribe\(\)/,
           "SessionWriter MUST NOT subscribe the global DebugLog firehose — that is the M×N fan-out the fix removed"
  end
end
