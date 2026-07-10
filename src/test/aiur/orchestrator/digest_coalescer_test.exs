defmodule Aiur.Orchestrator.DigestCoalescerTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentQueue, AgentQueueStore}
  alias Aiur.Orchestrator.DigestCoalescer

  test "coalesces queued digest events in id order" do
    first = AgentQueue.coordination_event("42", :events_digest, %{events: [%{id: 2, topic: "ticket.42.branch.push"}]})
    second = AgentQueue.coordination_event("42", :events_digest, %{events: [%{id: 1, topic: "ticket.42.branch.push"}]})
    {store, _} = AgentQueueStore.enqueue(AgentQueueStore.new(), first)
    {store, _} = AgentQueueStore.enqueue(store, second)
    {store, claimed} = AgentQueueStore.claim_next_deliverable(store, "42")

    {_store, item} = DigestCoalescer.coalesce_events_digests(store, "42", claimed)

    assert Enum.map(item.body.events, & &1.id) == [1, 2]
  end
end
