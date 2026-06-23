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
end
