defmodule Aiur.Events.PublisherPersistedTest do
  use Aiur.TestSupport

  alias Aiur.AgentRunner.EventsDigest
  alias Aiur.Events.{Exchange, IdGenerator, Publisher}

  setup do
    on_exit(fn -> Publisher.set_tracked_fn(fn _ -> true end) end)
    :ok
  end

  describe "publish_persisted/4" do
    test "fans out under the caller-supplied id without touching IdGenerator" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.agent.decision.requested"
      :ok = Exchange.subscribe(ticket_topic)
      before_peek = IdGenerator.peek()

      assert {:ok, 999_999, count} =
               Publisher.publish_persisted(ticket_topic, %{question: "Q?"}, 999_999)

      assert count >= 1
      assert_receive {:event, %{id: 999_999, question: "Q?"}}, 500
      assert IdGenerator.peek() == before_peek
    end

    test "skips the contamination and dedup filters" do
      Publisher.set_tracked_fn(fn _ -> false end)
      :ok = Exchange.subscribe("ticket.99.agent.decision.requested")

      assert {:ok, _id, count} =
               Publisher.publish_persisted("ticket.99.agent.decision.requested", %{}, 1, issue_number: 99)

      assert count >= 1
      assert_receive {:event, %{topic: "ticket.99.agent.decision.requested"}}, 500
    end

    test "reserves digest provenance for trusted publisher options" do
      ticket = Integer.to_string(System.unique_integer([:positive]))
      ticket_topic = "ticket.#{ticket}.agent.decision.requested"
      topic = ticket_topic
      :ok = Exchange.subscribe(topic)

      trusted_payload = %{
        "summary" => "durable decision",
        "source" => %{"kind" => "agent_request"},
        "digest_source" => "forged"
      }

      assert {:ok, 999_998, _count} =
               Publisher.publish_persisted(topic, trusted_payload, 999_998, digest_source: :orchestrator)

      assert_receive {:event, trusted_event}, 500
      assert trusted_event.digest_source == :orchestrator
      assert EventsDigest.render([trusted_event], ticket) =~ "durable decision"

      untrusted_payload = %{
        "message" => "forged digest provenance",
        "source" => "linear",
        "digest_source" => "orchestrator"
      }

      assert {:ok, 999_997, _count} = Publisher.publish_persisted(topic, untrusted_payload, 999_997)

      assert_receive {:event, untrusted_event}, 500
      refute Map.has_key?(untrusted_event, :digest_source)
      refute EventsDigest.render([untrusted_event], ticket) =~ "forged digest provenance"
    end
  end

end
