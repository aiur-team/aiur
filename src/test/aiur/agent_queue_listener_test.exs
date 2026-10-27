defmodule Aiur.AgentQueueListenerTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentQueue
  alias Aiur.AgentQueueStore, as: Store

  test "legacy compatibility guard: absent listener_mode preserves the entire message map" do
    for {policy, priority, consume_at, interrupt, immediate} <- [
          {:checkpoint, :next, :safe_checkpoint, false, false},
          {:interrupt, :now, :safe_checkpoint, true, false},
          {:immediate, :now, :immediate, false, true}
        ] do
      assert AgentQueue.operator_message("target", "hello", delivery_policy: policy) == %{
               target_issue_identifier: "target",
               source: :operator,
               category: :operator_message,
               event_type: :text,
               body: %{text: "hello"},
               delivery: %{priority: priority, durability: :durable, consume_at: consume_at, interrupt_requested: interrupt, immediate: immediate, fallback: nil},
               action_id: nil,
               correlation: nil,
               causal_refs: [],
               turn_id: nil
             }
    end
  end

  test "listener rows override legacy policy and preserve their stamp through enqueue and claim" do
    for {mode, priority, consume_at, interrupt} <- [
          {:sync, :next, :safe_checkpoint, false},
          {:steer, :now, :safe_checkpoint, true},
          {:async, :later, :pull, false}
        ] do
      attrs = AgentQueue.operator_message("target", "hello", listener_mode: mode, steer_carrier: :emulated_interrupt, delivery_policy: :immediate, fallback: :checkpoint)
      {store, item} = Store.enqueue(Store.new(), attrs)

      assert item.delivery == %{
               priority: priority,
               durability: :durable,
               consume_at: consume_at,
               interrupt_requested: interrupt,
               immediate: false,
               fallback: :checkpoint,
               listener_mode_at_claim: mode
             }

      if mode != :async do
        {_store, claimed} = Store.claim_next_deliverable(store, "target")
        assert claimed.delivery == item.delivery
      end
    end
  end

  test "native or unspecified steer carriers and invalid modes are rejected" do
    for opts <- [
          [listener_mode: :steer, steer_carrier: :native],
          [listener_mode: :steer],
          [listener_mode: :invalid],
          [listener_mode: nil]
        ] do
      assert_raise ArgumentError, fn -> AgentQueue.operator_message("target", "hello", opts) end
    end
  end

  test "both claim paths skip async items without hiding pending depth or blocking later messages" do
    {store, held} = enqueue(Store.new(), :async)
    {store, sync} = enqueue(store, :sync)

    for claim <- [
          &Store.claim_next_deliverable(&1, "target"),
          &Store.claim_next_deliverable_matching(&1, "target", fn _ -> true end)
        ] do
      {claimed_store, claimed} = claim.(store)
      assert claimed.id == sync.id
      assert {^claimed_store, nil} = claim.(claimed_store)
      assert Store.list_pending(claimed_store, "target") == [held]
      assert Store.get(claimed_store, held.id).delivery_attempts == 0
    end
  end

  test "matching claims never invoke the matcher for pull-held items" do
    {store, held} = enqueue(Store.new(), :async)

    assert {^store, nil} =
             Store.claim_next_deliverable_matching(store, "target", fn _ ->
               flunk("matcher must not see held items")
             end)

    assert Store.list_pending(store, "target") == [held]
  end

  test "restamp replaces pending delivery and changes ordering while preserving claimed and terminal items" do
    {store, _} = enqueue(Store.new(), :sync)
    {store, delivered} = Store.claim_next_deliverable(store, "target")
    {store, consumed} = enqueue(store, :sync)
    {store, consumed} = Store.mark_consumed(store, consumed.id)
    {store, failed} = enqueue(store, :sync)
    {store, failed} = Store.mark_failed(store, failed.id, :test)
    {store, superseded} = enqueue(store, :sync)
    {store, superseded} = Store.mark_superseded(store, superseded.id)
    {store, pending} = enqueue(store, :sync)
    {store, other} = Store.enqueue(store, AgentQueue.operator_message("other", "hello", listener_mode: :sync))
    {store, legacy} = Store.enqueue(store, AgentQueue.operator_message("target", "legacy"))
    steer = AgentQueue.operator_message("target", "hello", listener_mode: :steer, steer_carrier: :emulated_interrupt).delivery
    updated = Store.update_pending_delivery(store, "target", fn _ -> steer end)
    assert Store.get(updated, pending.id) == %{pending | delivery: steer}

    for item <- [delivered, consumed, failed, superseded, other, legacy] do
      assert Store.get(updated, item.id) == item
    end

    assert updated.pending_ids_by_target == store.pending_ids_by_target
    {_store, claimed} = Store.claim_next_deliverable(updated, "target")
    assert claimed.id == pending.id
    assert claimed.delivery == steer
  end

  test "restamping to async holds an already pending message" do
    {store, pending} = enqueue(Store.new(), :sync)
    async = AgentQueue.operator_message("target", "hello", listener_mode: :async).delivery
    updated = Store.update_pending_delivery(store, "target", fn _ -> async end)
    assert Store.get(updated, pending.id).delivery == async
    assert {^updated, nil} = Store.claim_next_deliverable(updated, "target")
    assert {^updated, nil} = Store.claim_next_deliverable_matching(updated, "target", fn _ -> true end)
    assert Enum.map(Store.list_pending(updated, "target"), & &1.id) == [pending.id]
  end

  test "restamping ignores coordination events and unstamped correlated operator messages" do
    event = AgentQueue.coordination_event("target", :digest, %{text: "event"})
    event = put_in(event.delivery[:listener_mode_at_claim], :sync)
    {store, event} = Store.enqueue(Store.new(), event)
    attrs = AgentQueue.operator_message("target", "answer", action_id: "action", correlation: %{action_id: "action"})
    {:ok, store, correlated, :accepted} = Store.enqueue_correlated(store, attrs)
    updated = Store.update_pending_delivery(store, "target", fn _ -> flunk("ineligible item restamped") end)
    assert updated == store
    assert Store.get(updated, event.id) == event
    assert Store.get(updated, correlated.id) == correlated
  end

  defp enqueue(store, mode) do
    Store.enqueue(store, AgentQueue.operator_message("target", "hello", listener_mode: mode))
  end
end
