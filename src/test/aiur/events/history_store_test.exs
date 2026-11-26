defmodule Aiur.Events.HistoryStoreTest do
  use Aiur.TestSupport

  alias Aiur.Events.{HistoryStore, Publisher, SubscriptionStore}

  defmodule FakeHistory do
    @behaviour HistoryStore

    @impl true
    def record(identifier, kind, event) do
      send(Application.fetch_env!(:aiur, :history_store_test_receiver), {:recorded, identifier, kind, event})
      :ok
    end
  end

  setup do
    previous = Application.fetch_env(:aiur, HistoryStore)
    receiver = Application.fetch_env(:aiur, :history_store_test_receiver)
    Application.put_env(:aiur, HistoryStore, FakeHistory)
    Application.put_env(:aiur, :history_store_test_receiver, self())
    identifier = "history-sink-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      SubscriptionStore.stop(identifier)
      SubscriptionStore.set_enqueue_fn(nil)
      restore_setting(HistoryStore, previous)
      restore_setting(:history_store_test_receiver, receiver)
    end)

    %{identifier: identifier}
  end

  test "routes bus writes to the configured store" do
    topic = "ticket.42.pr.merged"
    assert {:ok, event_id, _count} = Publisher.publish(topic, %{sha: "abc"}, issue_number: nil)
    assert_received {:recorded, "42", :emit, %{id: ^event_id, topic: ^topic, sha: "abc"}}
  end

  test "preserves agent and explicit self marker kinds" do
    for {topic, opts} <- [{"ticket.42.agent.progress", []}, {"ticket.42.pr.merged", [self_emit: true]}] do
      assert {:ok, event_id, _count} = Publisher.publish(topic, %{}, [issue_number: nil] ++ opts)
      assert_received {:recorded, "42", :self, %{id: ^event_id, topic: ^topic}}
    end
  end

  test "SubscriptionStore records successful initial delivery through the store", %{identifier: identifier} do
    SubscriptionStore.set_enqueue_fn(fn _, _ -> :ok end)
    pid = attach_store(identifier)
    event = %{id: 5, topic: "ticket.42.branch.push", sha: "abc"}
    send(pid, {:event, event})

    assert SubscriptionStore.snapshot(identifier).last_seen_event_id == 5
    assert_received {:recorded, ^identifier, :consumed, ^event}
  end

  test "SubscriptionStore records only the successful retry through the store", %{identifier: identifier} do
    parent = self()

    SubscriptionStore.set_enqueue_fn(fn _, event ->
      if Process.get(:history_sink_attempted, false) do
        :ok
      else
        Process.put(:history_sink_attempted, true)
        send(parent, {:enqueue_failed, event})
        {:error, :timeout}
      end
    end)

    pid = attach_store(identifier)
    event = %{id: 5, topic: "ticket.42.branch.push", sha: "abc"}
    send(pid, {:event, event})
    assert SubscriptionStore.snapshot(identifier).last_seen_event_id == nil
    assert_received {:enqueue_failed, ^event}
    refute_received {:recorded, ^identifier, :consumed, ^event}
    send(pid, {:retry_stalled})

    assert SubscriptionStore.snapshot(identifier).last_seen_event_id == 5
    assert_received {:recorded, ^identifier, :consumed, ^event}
    refute_received {:recorded, ^identifier, :consumed, ^event}
  end

  test "disabled or absent store is a no-op without preventing publication" do
    for setting <- [:none, :absent] do
      if setting == :absent,
        do: Application.delete_env(:aiur, HistoryStore),
        else: Application.put_env(:aiur, HistoryStore, setting)

      assert :ok = HistoryStore.record("42", :consumed, %{id: 5})
      assert {:ok, _, _} = Publisher.publish("ticket.42.pr.merged", %{}, issue_number: nil)
      refute_received {:recorded, "42", _, _}
    end
  end

  defp attach_store(identifier) do
    :ok = SubscriptionStore.attach(identifier)
    [{pid, _}] = Registry.lookup(Aiur.Events.SubscriptionStoreRegistry, identifier)
    pid
  end

  defp restore_setting(key, {:ok, value}), do: Application.put_env(:aiur, key, value)
  defp restore_setting(key, :error), do: Application.delete_env(:aiur, key)
end
