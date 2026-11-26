defmodule Aiur.AgentRunner.QueueDrainTextTest do
  use Aiur.TestSupport
  @moduletag :r7_characterization

  alias Aiur.AgentRunner.QueueDrain

  describe "queue_item_text/1" do
    test "extracts body text from an operator_message item" do
      item = %{category: :operator_message, body: %{text: "hello operator"}}

      assert QueueDrain.queue_item_text(item) == "hello operator"
    end

    test "renders an events_digest coordination event via EventsDigest" do
      event = %{id: 1, topic: "ticket.QD-01.agent.progress", source: :agent, message: "progress note"}
      item = %{category: :coordination_event, event_type: :events_digest, body: %{events: [event]}}

      result = QueueDrain.queue_item_text(item)

      assert result =~ "<aiur:events>"
      assert result =~ "progress note"
    end

    test "renders an urgent events_digest with the urgent attribute" do
      event = %{id: 1, topic: "ticket.QD-01.agent.progress", source: :agent, message: "blocker note"}

      item = %{
        category: :coordination_event,
        event_type: :events_digest,
        body: %{events: [event], urgent: true}
      }

      result = QueueDrain.queue_item_text(item)

      assert result =~ ~s(<aiur:events urgent="true">)
      assert result =~ "blocker note"
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
