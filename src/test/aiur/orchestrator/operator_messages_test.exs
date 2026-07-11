defmodule Aiur.Orchestrator.OperatorMessagesTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentQueueStore
  alias Aiur.Orchestrator.{OperatorMessages, State}

  test "reports checkpoint-only capabilities without a running agent" do
    state = %State{queue_store: AgentQueueStore.new()}

    assert OperatorMessages.issue_control_capabilities(state, "42") == %{
             accepts_operator_messages: false,
             accepted_delivery_policies: [:checkpoint],
             can_interrupt: false,
             immediate_delivery: false,
             queue_depth: 0,
             safe_checkpoints: [],
             status: :working
           }
  end
end
