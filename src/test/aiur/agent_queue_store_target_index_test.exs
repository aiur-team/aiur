defmodule Aiur.AgentQueueStoreTargetIndexTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentQueue, AgentQueueStore}
  alias Aiur.Orchestrator.{OperatorMessages, State}

  test "per-target reads cost the same however many items other targets hold" do
    cost = fn other_items ->
      store =
        Enum.reduce(1..other_items, AgentQueueStore.new(), fn n, acc ->
          {acc, _item} = AgentQueueStore.enqueue(acc, AgentQueue.operator_message("MT-OTHER-#{n}", "x"))
          acc
        end)

      {store, _item} = AgentQueueStore.enqueue(store, AgentQueue.operator_message("MT-887", "abc"))
      {:reductions, before} = Process.info(self(), :reductions)
      assert [_visible] = AgentQueueStore.list_visible_operator_messages(store, "MT-887")
      assert {_store, []} = AgentQueueStore.consume_delivered(store, "MT-887")
      {:reductions, after_reads} = Process.info(self(), :reductions)
      after_reads - before
    end

    # A full scan of `items` makes the large store cost ~100x the small one (#4962).
    assert cost.(10_000) < 2 * cost.(100)
  end

  test "duplicate digest enqueue cost does not grow with unrelated queue history" do
    duplicate_cost = fn other_items ->
      store =
        Enum.reduce(1..other_items, AgentQueueStore.new(), fn n, acc ->
          {acc, _item} = AgentQueueStore.enqueue(acc, AgentQueue.operator_message("MT-OTHER-#{n}", "x"))
          acc
        end)

      event = %{id: 73_501, topic: "ticket.MT-EVENT.branch.push"}
      digest = AgentQueue.coordination_event("MT-EVENT", :events_digest, %{events: [event]})
      {store, item} = AgentQueueStore.enqueue(store, digest)
      {store, _item} = AgentQueueStore.mark_failed(store, item.id, :recorded)
      state = %State{queue_store: store}

      warmed = OperatorMessages.enqueue_event_digest_item(state, "MT-EVENT", [event], event)
      assert warmed.queue_store.next_id == store.next_id
      :erlang.garbage_collect(self())
      {:reductions, before} = Process.info(self(), :reductions)
      next = OperatorMessages.enqueue_event_digest_item(state, "MT-EVENT", [event], event)
      assert next.queue_store.next_id == store.next_id
      assert map_size(next.queue_store.items) == map_size(store.items)
      {:reductions, after_enqueue} = Process.info(self(), :reductions)
      after_enqueue - before
    end

    # Scanning every stored item to reject a duplicate makes this path scale with history.
    assert duplicate_cost.(10_000) < 2 * duplicate_cost.(100)
  end
end
