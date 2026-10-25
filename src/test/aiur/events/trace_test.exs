defmodule Aiur.Events.TraceTest do
  use Aiur.TestSupport

  alias Aiur.Events.{DebugLog, Exchange, Publisher, SubscriptionStore, Trace}

  defmodule FakeTrace do
    @behaviour Trace
    @impl true
    def trace(kind, topic, opts) do
      send(Application.fetch_env!(:aiur, :trace_test_pid), {:trace, kind, topic, opts})
      :ok
    end
  end

  defmodule BrokenTrace do
    @behaviour Trace
    @impl true
    def trace(_kind, _topic, _opts), do: raise("broken trace sink")
  end

  setup do
    original = Application.fetch_env!(:aiur, Trace)
    Application.put_env(:aiur, :trace_test_pid, self())
    Application.put_env(:aiur, Trace, FakeTrace)

    on_exit(fn ->
      Application.put_env(:aiur, Trace, original)
      Application.delete_env(:aiur, :trace_test_pid)
      SubscriptionStore.set_enqueue_fn(nil)
    end)

    %{default_sink: original}
  end

  test "publish emits a trace through the configured sink" do
    topic = "ticket.42.pr.opened"
    assert {:ok, id, _count} = Publisher.publish(topic, %{title: "opened"})
    assert_receive {:trace, :publish, ^topic, opts}, 500
    assert opts == [id: id, body: %{title: "opened"}]
  end

  test "persisted publish emits a trace with the supplied id" do
    topic = "ticket.42.pr.opened"
    assert {:ok, 7, _count} = Publisher.publish_persisted(topic, %{}, 7)
    assert_receive {:trace, :publish, ^topic, [id: 7, body: %{}]}, 500
  end

  test "subscription delivery and stalled retry trace the receiving identifier" do
    identifier = "trace-#{System.unique_integer([:positive])}"
    parent = self()
    SubscriptionStore.set_enqueue_fn(fn _, _ -> {:error, :timeout} end)
    :ok = SubscriptionStore.attach(identifier)
    on_exit(fn -> SubscriptionStore.stop(identifier) end)
    [{pid, _}] = Registry.lookup(Aiur.Events.SubscriptionStoreRegistry, identifier)
    event = %{id: 7, topic: "ticket.42.pr.opened"}
    send(pid, {:event, event})
    assert SubscriptionStore.snapshot(identifier).last_seen_event_id == nil

    SubscriptionStore.set_enqueue_fn(fn _, event ->
      send(parent, {:enqueued, event.id})
      :ok
    end)

    send(pid, {:retry_stalled})
    assert_receive {:enqueued, 7}, 500
    assert_receive {:trace, :receive, "ticket.42.pr.opened", opts}, 500
    assert opts == [id: 7, identifier: identifier, body: event]

    next_event = %{event | id: 8}
    send(pid, {:event, next_event})
    assert_receive {:enqueued, 8}, 500
    assert_receive {:trace, :receive, "ticket.42.pr.opened", opts}, 500
    assert opts == [id: 8, identifier: identifier, body: next_event]
  end

  test "default sink preserves identical global and per-identifier debug entries", %{default_sink: default} do
    assert default == DebugLog
    identifier = "trace-#{System.unique_integer([:positive])}"
    topic = "ticket.#{identifier}.pr.opened"
    Application.put_env(:aiur, Trace, DebugLog)
    :ok = DebugLog.subscribe()
    :ok = DebugLog.subscribe(identifier)
    :ok = DebugLog.broadcast(:publish, "ticket.other.pr.opened", body: %{})
    assert {:ok, id, _count} = Publisher.publish(topic, %{})
    assert_receive {:event_debug, %{topic: ^topic} = entry}, 500
    assert_receive {:event_debug, %{topic: ^topic} = duplicate}, 500
    assert duplicate == entry
    assert Map.delete(entry, :at) == %{kind: :publish, topic: topic, id: id, identifier: nil, body: %{}}
    assert is_integer(entry.at)
  end

  test "disabled, absent and broken sinks leave bus delivery intact" do
    topic = "ticket.42.pr.opened"
    :ok = Exchange.subscribe(topic)
    :ok = DebugLog.subscribe()

    for sink <- [:none, :absent, BrokenTrace] do
      if sink == :absent, do: Application.delete_env(:aiur, Trace), else: Application.put_env(:aiur, Trace, sink)
      assert {:ok, id, _count} = Publisher.publish(topic, %{sink: sink})
      assert_receive {:event, %{id: ^id, sink: ^sink}}, 500
    end

    refute_receive {:event_debug, %{topic: ^topic}}, 50
  end
end
