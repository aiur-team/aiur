defmodule Aiur.Orchestrator.OperatorMessages.UnreadTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentQueue, AgentQueueStore}
  alias Aiur.Orchestrator.OperatorMessages.Capabilities
  alias Aiur.Orchestrator.State

  test "unread counts pending held operator messages only, even without a runner" do
    {store, held} = enqueue(AgentQueueStore.new(), :async)
    {store, consumed} = enqueue(store, :async)
    {store, _} = AgentQueueStore.mark_consumed(store, consumed.id)
    {store, failed} = enqueue(store, :async)
    {store, _} = AgentQueueStore.mark_failed(store, failed.id, :test)
    {store, superseded} = enqueue(store, :async)
    {store, _} = AgentQueueStore.mark_superseded(store, superseded.id)
    {store, _} = enqueue(store, :sync)
    {store, _} = AgentQueueStore.enqueue(store, AgentQueue.operator_message("other", "held", listener_mode: :async))
    event = AgentQueue.coordination_event("42", :events_digest, %{events: []})
    {store, _} = AgentQueueStore.enqueue(store, put_in(event.delivery.consume_at, :pull))
    state = %State{queue_store: store}
    result = Capabilities.issue_control_capabilities(state, "42")
    refute result.accepts_operator_messages
    # Preserve the existing queue-depth semantics of the pending index.
    assert result.queue_depth == 5
    assert result.listener == %{unread_count: 1, oldest_unread_at: held.inserted_at}
    assert Capabilities.issue_control_capabilities(state, "42", %{identifier: "42", control: %{}}).listener == result.listener
  end

  test "oldest unread uses insertion time and clears to nil" do
    {store, first} = enqueue(AgentQueueStore.new(), :async)
    {store, second} = enqueue(store, :async)
    earlier = DateTime.add(first.inserted_at, -60, :second)
    store = put_in(store.items[second.id].inserted_at, earlier)
    state = %State{queue_store: store}
    assert Capabilities.issue_control_capabilities(state, "42").listener == %{unread_count: 2, oldest_unread_at: earlier}
    {store, _} = AgentQueueStore.mark_consumed(store, first.id)
    {store, _} = AgentQueueStore.mark_consumed(store, second.id)
    assert Capabilities.issue_control_capabilities(%{state | queue_store: store}, "42").listener == %{unread_count: 0, oldest_unread_at: nil}
  end

  defp enqueue(store, mode), do: AgentQueueStore.enqueue(store, AgentQueue.operator_message("42", "message", listener_mode: mode))
end
