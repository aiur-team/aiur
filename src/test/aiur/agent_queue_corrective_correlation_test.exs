defmodule Aiur.AgentQueueCorrectiveCorrelationTest do
  use ExUnit.Case, async: true
  alias Aiur.AgentQueueStore

  test "corrective target marker cannot name a different delivery target" do
    attrs = %{
      source: :executor,
      category: :operator_message,
      event_type: nil,
      body: %{text: "Override"},
      action_id: "override",
      target_issue_identifier: "original",
      correlation: %{action_id: "override", corrective_target: "other"}
    }

    assert {:error, :target_mismatch} = AgentQueueStore.enqueue_correlated(AgentQueueStore.new(), attrs)
  end
end
