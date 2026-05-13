defmodule SymphonyElixir.AgentQueueTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{AgentQueue, AgentQueueStore}

  test "enqueue human message and claim it back with preserved delivery policy" do
    store = AgentQueueStore.new()

    {store, item} =
      AgentQueue.operator_message("MT-100", "focus on auth")
      |> then(&AgentQueueStore.enqueue(store, &1))

    assert item.target_issue_identifier == "MT-100"
    assert item.category == :operator_message
    assert item.event_type == :text
    assert item.body == %{text: "focus on auth"}
    assert item.delivery.priority == :next

    {store, claimed} = AgentQueueStore.claim_next_deliverable(store, "MT-100")

    assert claimed.id == item.id
    assert claimed.status == :delivered
    assert AgentQueueStore.list_pending(store, "MT-100") == []
  end

  test "coordination event remains claimable for a non-running issue later" do
    store = AgentQueueStore.new()

    {store, item} =
      AgentQueue.coordination_event("MT-200", :blocker_update, %{summary: "unblocked"})
      |> then(&AgentQueueStore.enqueue(store, &1))

    assert item.category == :coordination_event

    {store, claimed} = AgentQueueStore.claim_next_deliverable(store, "MT-200")
    assert claimed.id == item.id

    {_store, consumed} = AgentQueueStore.mark_consumed(store, item.id)
    assert consumed.status == :consumed
  end

  test "mark queue item delivered, consumed, failed, and superseded" do
    store = AgentQueueStore.new()
    {store, item} = AgentQueue.operator_message("MT-300", "hello") |> then(&AgentQueueStore.enqueue(store, &1))

    {store, delivered} = AgentQueueStore.claim_next_deliverable(store, "MT-300")
    assert delivered.status == :delivered

    {store, failed} = AgentQueueStore.mark_failed(store, item.id, :boom)
    assert failed.status == :failed
    assert failed.failure_reason == :boom

    {store, consumed} = AgentQueueStore.mark_consumed(store, item.id)
    assert consumed.status == :consumed

    {store, item2} = AgentQueue.operator_message("MT-300", "again") |> then(&AgentQueueStore.enqueue(store, &1))
    {_store, superseded} = AgentQueueStore.mark_superseded(store, item2.id)
    assert superseded.status == :superseded
  end

  test "dedupe repeated blocker events by superseding the pending predecessor" do
    store = AgentQueueStore.new()

    event = fn summary ->
      AgentQueue.coordination_event("MT-400", :blocker_update, %{summary: summary}, dedupe_key: "blocker:MT-1")
    end

    {store, first} = event.("still blocked") |> then(&AgentQueueStore.enqueue(store, &1))
    {store, second} = event.("now unblocked") |> then(&AgentQueueStore.enqueue(store, &1))

    assert AgentQueueStore.get(store, first.id).status == :superseded
    assert AgentQueueStore.get(store, second.id).status == :pending
    assert [pending_item] = AgentQueueStore.list_pending(store, "MT-400")
    assert pending_item.id == second.id
  end

  test "preserves priority ordering when operator messages and deferred events coexist" do
    store = AgentQueueStore.new()

    {store, event_item} =
      AgentQueue.coordination_event("MT-500", :blocker_update, %{summary: "later"}, priority: :later)
      |> then(&AgentQueueStore.enqueue(store, &1))

    {store, operator_item} =
      AgentQueue.operator_message("MT-500", "act soon")
      |> then(&AgentQueueStore.enqueue(store, &1))

    {store, claimed_first} = AgentQueueStore.claim_next_deliverable(store, "MT-500")
    {_store, claimed_second} = AgentQueueStore.claim_next_deliverable(store, "MT-500")

    assert claimed_first.id == operator_item.id
    assert claimed_second.id == event_item.id
  end

  test "returns empty or nil for missing targets and item ids" do
    store = AgentQueueStore.new()

    assert {^store, nil} = AgentQueueStore.claim_next_deliverable(store, "MT-404")
    assert AgentQueueStore.list_pending(store, "MT-404") == []
    assert AgentQueueStore.get(store, 999_999) == nil
    assert {^store, nil} = AgentQueueStore.mark_consumed(store, 999_999)
    assert {^store, nil} = AgentQueueStore.mark_failed(store, 999_999, :missing)
    assert {^store, nil} = AgentQueueStore.mark_superseded(store, 999_999)
  end

  test "supports non-pending supersede and explicit delivery metadata overrides" do
    store = AgentQueueStore.new()

    attrs = %{
      target_issue_identifier: "MT-777",
      source: :agent,
      category: :system_notice,
      event_type: :attention_needed,
      body: %{text: "look here"},
      delivery: %{
        priority: :now,
        durability: :ephemeral,
        consume_at: :turn_end_only,
        interrupt_requested: true,
        fallback: :queue_next
      }
    }

    {store, item} = AgentQueueStore.enqueue(store, attrs)
    assert item.delivery.priority == :now
    assert item.delivery.durability == :ephemeral
    assert item.delivery.consume_at == :turn_end_only
    assert item.delivery.interrupt_requested == true
    assert item.delivery.fallback == :queue_next

    {store, claimed} = AgentQueueStore.claim_next_deliverable(store, "MT-777")
    assert claimed.id == item.id

    {_store, superseded} = AgentQueueStore.mark_superseded(store, item.id)
    assert superseded.status == :superseded
  end

  test "falls back for unknown priority values and keeps unrelated dedupe keys pending" do
    store = AgentQueueStore.new()

    attrs = %{
      target_issue_identifier: "MT-778",
      source: :system,
      category: :coordination_event,
      event_type: :status_ping,
      body: %{text: "odd priority"},
      delivery: %{priority: :unexpected},
      dedupe_key: "dedupe-a"
    }

    {store, first} = AgentQueueStore.enqueue(store, attrs)

    {store, second} =
      AgentQueueStore.enqueue(store, %{attrs | dedupe_key: "dedupe-b", body: %{text: "second"}})

    [claimed_first, claimed_second] =
      store
      |> AgentQueueStore.list_pending("MT-778")
      |> Enum.map(& &1.id)
      |> then(fn [first_id, second_id] ->
        [AgentQueueStore.get(store, first_id), AgentQueueStore.get(store, second_id)]
      end)

    assert claimed_first.id == first.id
    assert claimed_second.id == second.id
  end
end
