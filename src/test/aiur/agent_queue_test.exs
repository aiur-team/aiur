defmodule Aiur.AgentQueueTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentQueue, AgentQueueStore}

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

  test "immediate delivery policy flags pass-through, now priority, immediate consume point" do
    item = AgentQueue.operator_message("MT-110", "steer now", delivery_policy: :immediate)

    assert item.delivery.immediate == true
    assert item.delivery.priority == :now
    assert item.delivery.consume_at == :immediate
    # Immediate is pass-through, not aiur-driven interrupt.
    assert item.delivery.interrupt_requested == false
  end

  test "immediate flag survives enqueue (deliver-now reaches the running REPL)" do
    # Regression: AgentQueueStore.normalize_delivery used to drop :immediate,
    # downgrading every claude-repl operator message to checkpoint delivery so
    # the orchestrator's deliver-now (interrupt_requested or immediate) was
    # always false and the agent never got the mid-turn paste.
    store = AgentQueueStore.new()

    {_store, item} =
      AgentQueue.operator_message("MT-112", "steer now", delivery_policy: :immediate)
      |> then(&AgentQueueStore.enqueue(store, &1))

    assert item.delivery.immediate == true
    # This is exactly the orchestrator's deliver-now predicate.
    assert item.delivery[:interrupt_requested] == true or item.delivery[:immediate] == true
  end

  test "default (checkpoint) delivery holds at a safe checkpoint, not immediate" do
    item = AgentQueue.operator_message("MT-111", "later is fine")

    assert item.delivery.immediate == false
    assert item.delivery.consume_at == :safe_checkpoint
    assert item.delivery.priority == :next
    assert item.delivery.interrupt_requested == false
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

    assert {^store, nil} =
             AgentQueueStore.claim_next_deliverable_matching(
               store,
               "MT-404",
               &match?(%{category: :operator_message}, &1)
             )

    assert AgentQueueStore.list_pending(store, "MT-404") == []
    assert AgentQueueStore.get(store, 999_999) == nil
    assert {^store, nil} = AgentQueueStore.mark_consumed(store, 999_999)
    assert {^store, nil} = AgentQueueStore.mark_failed(store, 999_999, :missing)
    assert {^store, nil} = AgentQueueStore.mark_superseded(store, 999_999)
  end

  test "claim next deliverable matching leaves non-matching items pending" do
    store = AgentQueueStore.new()

    {store, event_item} =
      AgentQueue.coordination_event("MT-779", :blocker_update, %{summary: "still blocked"})
      |> then(&AgentQueueStore.enqueue(store, &1))

    {store, operator_item} =
      AgentQueue.operator_message("MT-779", "resume with context")
      |> then(&AgentQueueStore.enqueue(store, &1))

    {store, claimed} =
      AgentQueueStore.claim_next_deliverable_matching(
        store,
        "MT-779",
        &match?(%{category: :operator_message}, &1)
      )

    assert claimed.id == operator_item.id
    assert AgentQueueStore.get(store, event_item.id).status == :pending
    assert [pending_item] = AgentQueueStore.list_pending(store, "MT-779")
    assert pending_item.id == event_item.id
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

  test "restore pending returns delivered item to visible queue" do
    store = AgentQueueStore.new()
    {store, item} = AgentQueue.operator_message("MT-880", "abc") |> then(&AgentQueueStore.enqueue(store, &1))
    {store, _claimed} = AgentQueueStore.claim_next_deliverable(store, "MT-880")

    {store, restored} = AgentQueueStore.restore_pending(store, item.id)

    assert restored.status == :pending
    assert [visible_item] = AgentQueueStore.list_visible_operator_messages(store, "MT-880")
    assert visible_item.id == item.id
    assert [pending_item] = AgentQueueStore.list_pending(store, "MT-880")
    assert pending_item.id == item.id
  end

  test "restore pending is idempotent for pending, consumed, and missing items" do
    store = AgentQueueStore.new()
    {store, pending_item} = AgentQueue.operator_message("MT-883", "abc") |> then(&AgentQueueStore.enqueue(store, &1))

    {store, restored_pending} = AgentQueueStore.restore_pending(store, pending_item.id)
    assert restored_pending.status == :pending

    {store, _claimed} = AgentQueueStore.claim_next_deliverable(store, "MT-883")
    {store, consumed} = AgentQueueStore.mark_consumed(store, pending_item.id)
    assert consumed.status == :consumed

    {store, restored_consumed} = AgentQueueStore.restore_pending(store, pending_item.id)
    assert restored_consumed.status == :consumed

    assert {^store, nil} = AgentQueueStore.restore_pending(store, 999_999)
  end

  test "restore pending avoids duplicate pending ids" do
    store = AgentQueueStore.new()
    {store, item} = AgentQueue.operator_message("MT-886", "abc") |> then(&AgentQueueStore.enqueue(store, &1))
    {store, _claimed} = AgentQueueStore.claim_next_deliverable(store, "MT-886")

    store = %{store | pending_ids_by_target: %{"MT-886" => [item.id]}}
    {store, restored} = AgentQueueStore.restore_pending(store, item.id)

    assert restored.status == :pending
    assert Enum.map(AgentQueueStore.list_pending(store, "MT-886"), & &1.id) == [item.id]
  end

  test "visible operator messages include pending and delivered items" do
    store = AgentQueueStore.new()
    {store, first} = AgentQueue.operator_message("MT-881", "abc") |> then(&AgentQueueStore.enqueue(store, &1))
    {store, second} = AgentQueue.operator_message("MT-881", "def") |> then(&AgentQueueStore.enqueue(store, &1))
    {store, _claimed} = AgentQueueStore.claim_next_deliverable(store, "MT-881")

    assert [%{id: first_id}, %{id: second_id}] = AgentQueueStore.list_visible_operator_messages(store, "MT-881")
    assert first_id == first.id
    assert second_id == second.id
  end

  test "visible operator messages excludes non-operator and terminal items" do
    store = AgentQueueStore.new()

    {store, operator_item} =
      AgentQueue.operator_message("MT-884", "abc")
      |> then(&AgentQueueStore.enqueue(store, &1))

    {store, event_item} =
      AgentQueue.coordination_event("MT-884", :blocker_update, %{summary: "hidden"})
      |> then(&AgentQueueStore.enqueue(store, &1))

    {store, _claimed_operator} = AgentQueueStore.claim_next_deliverable(store, "MT-884")
    {store, _consumed_operator} = AgentQueueStore.mark_consumed(store, operator_item.id)
    {store, _failed_event} = AgentQueueStore.mark_failed(store, event_item.id, :boom)

    assert AgentQueueStore.list_visible_operator_messages(store, "MT-884") == []
  end

  test "consume and restore delivered update all in-flight items for a target" do
    store = AgentQueueStore.new()
    {store, item1} = AgentQueue.operator_message("MT-882", "abc") |> then(&AgentQueueStore.enqueue(store, &1))
    {store, item2} = AgentQueue.operator_message("MT-882", "def") |> then(&AgentQueueStore.enqueue(store, &1))
    {store, _claimed1} = AgentQueueStore.claim_next_deliverable(store, "MT-882")
    {store, _claimed2} = AgentQueueStore.claim_next_deliverable(store, "MT-882")

    {store, restored} = AgentQueueStore.restore_delivered(store, "MT-882")
    assert Enum.map(restored, & &1.id) == [item1.id, item2.id]
    assert Enum.all?(restored, &(&1.status == :pending))

    {store, _reclaimed1} = AgentQueueStore.claim_next_deliverable(store, "MT-882")
    {store, _reclaimed2} = AgentQueueStore.claim_next_deliverable(store, "MT-882")
    {_store, consumed} = AgentQueueStore.consume_delivered(store, "MT-882")

    assert Enum.map(consumed, & &1.id) == [item1.id, item2.id]
    assert Enum.all?(consumed, &(&1.status == :consumed))
  end

  test "fail delivered marks in-flight items failed for a target" do
    store = AgentQueueStore.new()
    {store, item} = AgentQueue.operator_message("MT-885", "abc") |> then(&AgentQueueStore.enqueue(store, &1))
    {store, _claimed} = AgentQueueStore.claim_next_deliverable(store, "MT-885")

    {_store, [failed]} = AgentQueueStore.fail_delivered(store, "MT-885", :turn_failed)

    assert failed.id == item.id
    assert failed.status == :failed
    assert failed.failure_reason == :turn_failed
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
