defmodule Aiur.AgentQueueStoreTargetIndexTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentQueue, AgentQueueStore}

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

  test "queued event ID lookup cost does not grow with unrelated queue history" do
    lookup_cost = fn other_items ->
      store =
        Enum.reduce(1..other_items, AgentQueueStore.new(), fn n, acc ->
          {acc, _item} = AgentQueueStore.enqueue(acc, AgentQueue.operator_message("MT-OTHER-#{n}", "x"))
          acc
        end)

      {store, event_item} =
        AgentQueue.coordination_event("MT-EVENT", :events_digest, %{events: [%{id: 73_501}]})
        |> then(&AgentQueueStore.enqueue(store, &1))

      {store, _failed} = AgentQueueStore.mark_failed(store, event_item.id, :recorded)
      {:reductions, before} = Process.info(self(), :reductions)
      assert AgentQueueStore.queued_event_id?(store, 73_501)
      {:reductions, after_lookup} = Process.info(self(), :reductions)
      after_lookup - before
    end

    # Rebuilding the ID set from `items` makes lookup reductions scale with unrelated history.
    assert lookup_cost.(10_000) < 2 * lookup_cost.(100)
  end
end
