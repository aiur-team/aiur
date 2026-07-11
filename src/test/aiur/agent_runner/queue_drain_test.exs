defmodule Aiur.AgentRunner.QueueDrainTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.QueueDrain
  alias Aiur.Issue

  describe "claim_after_queue_update/3" do
    test "returns :ignored when deliver_now? is false" do
      assert QueueDrain.claim_after_queue_update(self(), "QD-01", false) == :ignored
    end
  end

  describe "record_operator_delivery/2" do
    test "returns :ok for a non-operator-message item" do
      item = %{category: :coordination_event, id: 1}
      issue = %Issue{identifier: "QD-01", id: "gid-qd01"}

      assert QueueDrain.record_operator_delivery(item, issue) == :ok
    end

    test "returns :ok when issue has no binary identifier" do
      item = %{category: :operator_message, id: 1}
      issue = %Issue{identifier: nil, id: "gid-qd02"}

      assert QueueDrain.record_operator_delivery(item, issue) == :ok
    end
  end

  describe "queue_item_text/1" do
    test "extracts body text from an operator_message item" do
      item = %{category: :operator_message, body: %{text: "hello operator"}}

      assert QueueDrain.queue_item_text(item) == "hello operator"
    end

    test "renders an events_digest coordination event via EventsDigest" do
      event = %{id: 1, topic: "ticket.QD-01.agent.progress", message: "progress note"}
      item = %{category: :coordination_event, event_type: :events_digest, body: %{events: [event]}}

      result = QueueDrain.queue_item_text(item)

      assert result =~ "<aiur:events>"
      assert result =~ "progress note"
    end

    test "returns summary for other coordination events" do
      item = %{
        category: :coordination_event,
        event_type: :some_kind,
        body: %{summary: "coordination summary"}
      }

      result = QueueDrain.queue_item_text(item)

      assert result =~ "coordination summary"
      assert result =~ "some_kind"
    end

    test "falls back to inspect for unknown item shapes" do
      item = %{category: :unknown}

      result = QueueDrain.queue_item_text(item)

      assert is_binary(result)
    end
  end
end
