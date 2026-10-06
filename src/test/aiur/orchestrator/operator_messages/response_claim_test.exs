defmodule Aiur.Orchestrator.OperatorMessages.ResponseClaimTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentQueue, AgentQueueStore}
  alias Aiur.Orchestrator.{OperatorMessages, State}

  test "response command bypasses ordinary messages without claiming another ticket or a prefix lookalike" do
    {store, ordinary} =
      AgentQueueStore.enqueue(
        AgentQueueStore.new(),
        AgentQueue.operator_message("MUSE-1", "continue later")
      )

    {store, lookalike} =
      AgentQueueStore.enqueue(store, AgentQueue.operator_message("MUSE-1", "/approve-all yes"))

    {store, foreign} =
      AgentQueueStore.enqueue(store, AgentQueue.operator_message("OTHER", "/approve a b c"))

    {store, response} =
      AgentQueueStore.enqueue(store, AgentQueue.operator_message("MUSE-1", "/approve a b c"))

    assert {:reply, {:ok, claimed}, next} =
             OperatorMessages.claim_operator_response_call(
               %State{queue_store: store},
               "MUSE-1",
               "/approve"
             )

    assert claimed.id == response.id
    assert claimed.status == :delivered

    for pending <- [ordinary, lookalike, foreign] do
      assert AgentQueueStore.get(next.queue_store, pending.id).status == :pending
    end

    assert {:reply, :empty, _} =
             OperatorMessages.claim_operator_response_call(next, "MUSE-1", "/approve")

    assert {:reply, {:ok, next_ordinary}, _} =
             OperatorMessages.claim_next_operator_queue_item_call(next, "MUSE-1")

    assert next_ordinary.id == ordinary.id
  end
end
