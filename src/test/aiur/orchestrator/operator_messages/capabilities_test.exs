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
             %{id: first_item.id, text: "operator text", status: :queued},
             %{id: malformed_item.id, text: "", status: :queued}
           ]
  end

  test "keeps a claimed message queued until provider acknowledgement" do
    {store, item} =
      AgentQueue.operator_message("42", "operator text")
      |> then(&AgentQueueStore.enqueue(AgentQueueStore.new(), &1))

    {claimed_store, _claimed} = AgentQueueStore.claim_next_deliverable(store, "42")

    assert Capabilities.pending_operator_messages_for_issue(
             %State{queue_store: claimed_store},
             "42"
           ) == [%{id: item.id, text: "operator text", status: :queued}]

    {delivered_store, _acknowledged} =
      AgentQueueStore.mark_provider_delivered(claimed_store, item.id, %{
        turn_id: "turn-1"
      })

    assert Capabilities.pending_operator_messages_for_issue(
             %State{queue_store: delivered_store},
             "42"
           ) == [%{id: item.id, text: "operator text", status: :delivered}]

    {failed_store, _failed} =
      AgentQueueStore.mark_failed(claimed_store, item.id, :provider_down)

    assert Capabilities.pending_operator_messages_for_issue(
             %State{queue_store: failed_store},
             "42"
           ) == [%{id: item.id, text: "operator text", status: :failed}]
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
