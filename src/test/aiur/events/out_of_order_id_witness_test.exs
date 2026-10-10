defmodule Aiur.Events.OutOfOrderIdWitnessTest do
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, IdGenerator, SubscriptionStore}
  alias Aiur.Executor.Claims
  alias Aiur.{ExecutorListener, ExecutorWakeInbox}

  # Witness, deliberately green on main: not a fix or change coverage.
  # A delivery fix belongs to U3 (contract O-4).
  setup do
    identifier = "witness-#{System.unique_integer([:positive])}"
    test_pid = self()

    SubscriptionStore.set_enqueue_fn(fn ticket, event ->
      send(test_pid, {:enqueued, ticket, event.id})
      :ok
    end)

    on_exit(fn ->
      SubscriptionStore.stop(identifier)
      SubscriptionStore.set_enqueue_fn(nil)
    end)

    %{identifier: identifier}
  end

  test "SubscriptionStore drops a lower id delivered after a higher id (witness)", %{identifier: ticket} do
    topic = "ticket.#{ticket}.pr.review_comment"
    :ok = SubscriptionStore.attach(ticket)
    :ok = SubscriptionStore.add_subscription(ticket, topic, "auto:witness")
    [{consumer, _}] = Registry.lookup(Aiur.Events.SubscriptionStoreRegistry, ticket)

    {low, high} = interleave(fn id -> %{id: id, topic: topic} end, consumer)

    assert_received {:enqueued, ^ticket, ^high}
    refute_received {:enqueued, ^ticket, ^low}
    assert SubscriptionStore.snapshot(ticket).last_seen_event_id == high
  end

  test "ExecutorListener drops a lower executor.* id delivered after a higher id (witness)" do
    consumer = start_listener()
    assert :sys.get_state(consumer).watermark == 0

    {_low, high} = interleave(fn id -> %{"id" => id, "topic" => "executor.custom.witness"} end, consumer)

    # Without the freshness gate, delivering low rewinds the watermark to low.
    assert :sys.get_state(consumer).watermark == high
  end

  test "ExecutorListener wake path delivers both ids regardless of order (witness)", %{identifier: ticket} do
    inbox = start_supervised!({ExecutorWakeInbox, name: Aiur.ExecutorWakeInbox.OutOfOrderWitness, debounce_ms: 10})
    consumer = start_listener(inbox: inbox)
    topic = "ticket.#{ticket}.pr.opened"

    # Flush each delivery to keep the inbox's per-ticket debounce from merging ids.
    observe = fn id ->
      send(inbox, :flush)
      assert {:ok, [%{"event_id" => ^id, "topic" => ^topic, "ticket" => ^ticket} = record]} = ExecutorWakeInbox.wait(0, inbox)
      :ok = ack_as_owner([record], inbox)
    end

    interleave(fn id -> %{"id" => id, "topic" => topic} end, consumer, observe)
    assert :sys.get_state(consumer).watermark == 0
  end

  defp start_listener(opts \\ []) do
    start_supervised!(
      {ExecutorListener,
       Keyword.merge(
         [name: Aiur.ExecutorListener.OutOfOrderWitness, patterns: ["executor.#", "ticket.*.pr.opened"], reconcile?: false, resubscribe_interval_ms: :infinity],
         opts
       )}
    )
  end

  defp interleave(event, consumer, observe \\ fn _id -> :ok end) do
    parent = self()

    first = Task.async(fn -> delayed_publish(parent, event, consumer) end)
    assert_receive {:allocated, low}, 1_000
    second = Task.async(fn -> publish_and_barrier(IdGenerator.next_id(), event, consumer) end)
    high = Task.await(second)
    assert high > low
    observe.(high)
    send(first.pid, :deliver)
    assert Task.await(first) == low
    observe.(low)
    {low, high}
  end

  defp delayed_publish(parent, event, consumer) do
    id = IdGenerator.next_id()
    send(parent, {:allocated, id})

    receive do
      :deliver -> publish_and_barrier(id, event, consumer)
    end
  end

  defp publish_and_barrier(id, event, consumer) do
    payload = event.(id)
    assert Exchange.publish(payload[:topic] || payload["topic"], payload) >= 1
    # The publisher sends both the event and barrier, preserving mailbox order.
    :sys.get_state(consumer)
    id
  end

  defp ack_as_owner(records, server) do
    {:ok, _claim} = Claims.claim("test-owner")
    :ok = ExecutorWakeInbox.acknowledge_as("test-owner", records, server)
  end
end
