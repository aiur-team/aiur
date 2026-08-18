defmodule Aiur.Orchestrator.OperatorMessages.MessageStatusTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentQueue, AgentQueueStore}
  alias Aiur.Orchestrator.{OperatorMessages, State}

  # `send_operator_message/2` answers with a queue handle, so `aiur message`
  # needs a way to ask what actually became of that handle before it may claim
  # delivery (#1824). The status has to track the queue item's real lifecycle,
  # not a field the CLI sets for itself.
  test "reports the live queue lifecycle of one enqueued operator message" do
    attrs = AgentQueue.operator_message("repo#44", "ship it", delivery_policy: :interrupt, fallback: :queue_next)
    {queue_store, item} = AgentQueueStore.enqueue(AgentQueueStore.new(), attrs)
    state = %State{queue_store: queue_store}

    assert {:reply, {:ok, :pending}, state} = OperatorMessages.operator_message_status_call(state, item.id)

    # The agent claims the message the way the runner does.
    {claimed_store, claimed} = AgentQueueStore.claim_next_deliverable(state.queue_store, "repo#44")
    assert claimed.id == item.id
    state = %{state | queue_store: claimed_store}

    assert {:reply, {:ok, :delivered}, state} = OperatorMessages.operator_message_status_call(state, item.id)

    {consumed_store, _consumed} = AgentQueueStore.mark_consumed(state.queue_store, item.id)
    state = %{state | queue_store: consumed_store}

    assert {:reply, {:ok, :consumed}, _state} = OperatorMessages.operator_message_status_call(state, item.id)
  end

  test "reports an unknown request id rather than inventing an outcome" do
    state = %State{queue_store: AgentQueueStore.new()}

    assert {:reply, {:error, :unknown_message}, _state} =
             OperatorMessages.operator_message_status_call(state, 4_242)
  end
end
