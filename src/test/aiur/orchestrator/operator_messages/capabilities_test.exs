defmodule Aiur.Orchestrator.OperatorMessages.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias Aiur.{AgentQueue, AgentQueueStore}
  alias Aiur.Orchestrator.OperatorMessages.Capabilities
  alias Aiur.Orchestrator.State

  test "reports checkpoint-only capabilities without a running agent" do
    state = %State{queue_store: AgentQueueStore.new()}

    assert Capabilities.issue_control_capabilities(state, "42") == %{
             accepts_operator_messages: false,
             accepted_delivery_policies: [:checkpoint],
             can_interrupt: false,
             immediate_delivery: false,
             pending_control: nil,
             queue_depth: 0,
             safe_checkpoints: [],
             status: :working,
             unit_control: :unsupported
           }
  end

  test "reports interrupt capabilities and pending queue depth for a running agent" do
    state =
      "42"
      |> state_with_running_entry(%{
        can_interrupt: true,
        immediate_delivery: false,
        safe_checkpoints: [:notification, :tool_result],
        status: :sleeping
      })
      |> enqueue(AgentQueue.operator_message("42", "operator text"))
      |> enqueue(AgentQueue.coordination_event("42", :events_digest, %{events: []}))

    assert Capabilities.issue_control_capabilities(state, "42") == %{
             accepts_operator_messages: true,
             accepted_delivery_policies: [:checkpoint, :interrupt],
             can_interrupt: true,
             immediate_delivery: false,
             pending_control: nil,
             queue_depth: 2,
             safe_checkpoints: [:notification, :tool_result],
             status: :sleeping,
             unit_control: :request_only
           }
  end

  test "immediate delivery replaces checkpoint and interrupt policies" do
    state =
      state_with_running_entry("42", %{
        can_interrupt: true,
        immediate_delivery: true,
        application_confirmation: :confirmed,
        safe_checkpoints: [:notification],
        status: :working
      })

    assert %{
             accepted_delivery_policies: [:immediate],
             can_interrupt: true,
             immediate_delivery: true,
             unit_control: :confirmed
           } = Capabilities.issue_control_capabilities(state, "42")
  end

  test "projects visible operator messages without using Access on queue structs" do
    {store, first_item} =
      AgentQueueStore.new()
      |> AgentQueueStore.enqueue(AgentQueue.operator_message("42", "operator text"))

    {store, malformed_item} =
      store
      |> AgentQueueStore.enqueue(AgentQueue.operator_message("42", "placeholder"))

    store = put_in(store.items[malformed_item.id].body, %{})
    state = %State{queue_store: store}

    assert Capabilities.pending_operator_messages_for_issue(state, "42") == [
             %{id: first_item.id, text: "operator text", status: :pending},
             %{id: malformed_item.id, text: "", status: :pending}
           ]
  end

  defp state_with_running_entry(identifier, control) do
    %State{
      queue_store: AgentQueueStore.new(),
      running: %{"issue-#{identifier}" => %{identifier: identifier, control: control}}
    }
  end

  defp enqueue(%State{} = state, attrs) do
    {queue_store, _item} = AgentQueueStore.enqueue(state.queue_store, attrs)
    %{state | queue_store: queue_store}
  end
end
