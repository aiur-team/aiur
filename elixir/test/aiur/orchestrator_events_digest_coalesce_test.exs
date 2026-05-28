defmodule Aiur.OrchestratorEventsDigestCoalesceTest do
  @moduledoc """
  Drain-time coalesce: pending `:events_digest` queue items for the same identifier
  fold into a single delivery at drain checkpoint. Per-event granularity
  stays at the enqueue boundary (one queue item per publish) so
  `[event:consumed]` markers and cursor advance still see each event;
  the merge happens only at drain.
  """

  use ExUnit.Case, async: true

  alias Aiur.{AgentQueue, AgentQueueStore, Orchestrator}

  defp enqueue_events_digest(store, identifier, event) do
    item = AgentQueue.coordination_event(identifier, :events_digest, %{events: [event]}, source: :system)
    {store, _item} = AgentQueueStore.enqueue(store, item)
    store
  end

  defp event(id) when is_integer(id) do
    %{id: id, topic: "ticket.99.branch.push", message: "push ##{id}"}
  end

  test "single events_digest item passes through unchanged" do
    store =
      AgentQueueStore.new()
      |> enqueue_events_digest("99", event(1))

    {_store, item} = Orchestrator.coalesce_for_test(store, "99")

    assert item.event_type == :events_digest
    assert [%{id: 1}] = item.body.events
  end

  test "three pending events_digest items fold into one with all events" do
    store =
      AgentQueueStore.new()
      |> enqueue_events_digest("99", event(1))
      |> enqueue_events_digest("99", event(2))
      |> enqueue_events_digest("99", event(3))

    {store, item} = Orchestrator.coalesce_for_test(store, "99")

    assert [%{id: 1}, %{id: 2}, %{id: 3}] = item.body.events

    # All three items were claimed — next drain returns nothing.
    {_store, follow_up} = AgentQueueStore.claim_next_deliverable(store, "99")
    assert follow_up == nil
  end

  test "out-of-order events are sorted by id in the merged body" do
    store =
      AgentQueueStore.new()
      |> enqueue_events_digest("99", event(7))
      |> enqueue_events_digest("99", event(1))
      |> enqueue_events_digest("99", event(3))

    {_store, item} = Orchestrator.coalesce_for_test(store, "99")

    assert Enum.map(item.body.events, & &1.id) == [1, 3, 7]
  end

  test "empty queue returns nil" do
    {_store, item} = Orchestrator.coalesce_for_test(AgentQueueStore.new(), "99")

    assert item == nil
  end

  test "non-events_digest items pass through without coalescing" do
    operator_item = AgentQueue.operator_message("99", "hi", source: :operator)

    {store, _} = AgentQueueStore.enqueue(AgentQueueStore.new(), operator_item)
    store = enqueue_events_digest(store, "99", event(1))

    # First claim returns the operator message (FIFO), unchanged.
    {store, item} = Orchestrator.coalesce_for_test(store, "99")
    assert item.category == :operator_message

    # Second claim returns the digest, still standalone.
    {_store, next} = Orchestrator.coalesce_for_test(store, "99")
    assert next.event_type == :events_digest
    assert [%{id: 1}] = next.body.events
  end

  test "items for other identifiers are not coalesced" do
    store =
      AgentQueueStore.new()
      |> enqueue_events_digest("99", event(1))
      |> enqueue_events_digest("100", event(2))
      |> enqueue_events_digest("99", event(3))

    {store, item_99} = Orchestrator.coalesce_for_test(store, "99")

    # #99 gets two events folded; #100's event stays for its own drain.
    assert Enum.map(item_99.body.events, & &1.id) == [1, 3]

    {_store, item_100} = Orchestrator.coalesce_for_test(store, "100")
    assert Enum.map(item_100.body.events, & &1.id) == [2]
  end
end
