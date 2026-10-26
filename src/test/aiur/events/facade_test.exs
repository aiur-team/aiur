defmodule Aiur.Events.FacadeTest do
  use Aiur.TestSupport

  alias Aiur.Events
  alias Aiur.Events.SubscriptionStore

  test "facade delegates to the bus with identical results" do
    assert Events.exchange_server() == Aiur.Events.Exchange
    assert Events.publisher_available?()

    ticket = Integer.to_string(System.unique_integer([:positive]))
    topic = "ticket.#{ticket}.facade.published"
    pattern = "ticket.#{ticket}.facade.*"

    assert :ok = Events.subscribe(pattern)
    assert pattern in Events.bindings_for(self())
    assert Events.matches?(pattern, topic)
    refute Events.matches?(pattern, "executor.facade.published")

    assert {:ok, id, count} = Events.publish(topic, %{value: "live"})
    assert count >= 1
    receive_barrier({:event, %{id: ^id, topic: ^topic, value: "live"}})

    next_id = Events.next_id()
    assert next_id > id
    assert Events.peek() >= next_id
    assert {:ok, durable_id} = Events.reserve_durable_id()
    assert durable_id > next_id
    assert {:ok, ^durable_id, persisted_count} = Events.publish_persisted(topic, %{value: "persisted"}, durable_id)
    assert persisted_count >= 1
    receive_barrier({:event, %{id: ^durable_id, topic: ^topic, value: "persisted"}})

    assert {:error, :decision_requires_durable_publish} = Events.publish("ticket.#{ticket}.agent.decision.requested", %{})
    assert {:error, :executor_namespace_rejects_github_source} = Events.publish("executor.facade.published", %{}, source: "github")
    assert :ok = Events.set_tracked_fn(fn _ -> false end)
    assert :filtered = Events.publish(topic, %{}, issue_number: ticket)

    assert :ok = Events.unsubscribe(pattern)
    refute pattern in Events.bindings_for(self())
  end

  test "facade reports whether a subscription store matches a topic" do
    identifier = "facade-#{System.unique_integer([:positive])}"
    pattern = "ticket.#{identifier}.#"
    topic = "ticket.#{identifier}.agent.progress"

    :ok = SubscriptionStore.attach(identifier)
    on_exit(fn -> SubscriptionStore.stop(identifier) end)
    :ok = SubscriptionStore.add_subscription(identifier, pattern, "manual:agent")

    assert Events.any_subscriber_matches?(topic)
    refute Events.any_subscriber_matches?("executor.command.requested")
  end
end
