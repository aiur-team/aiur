defmodule Aiur.Events.SubscriptionStoreReplayTest do
  use ExUnit.Case, async: false
  alias Aiur.Events.SubscriptionStore

  setup do
    tmp = Aiur.TestSupport.tmp_root!("subscription_replay")
    original = Application.get_env(:aiur, :runtime_state_dir)
    Application.put_env(:aiur, :runtime_state_dir, tmp)
    id = "replay-#{System.unique_integer([:positive])}"
    :ok = SubscriptionStore.attach(id)
    :ok = SubscriptionStore.advance_cursor(id, 99)
    [{pid, _}] = Registry.lookup(Aiur.Events.SubscriptionStoreRegistry, id)

    on_exit(fn ->
      SubscriptionStore.stop(id)
      SubscriptionStore.set_enqueue_fn(nil)
      if original, do: Application.put_env(:aiur, :runtime_state_dir, original), else: Application.delete_env(:aiur, :runtime_state_dir)
      File.rm_rf(tmp)
    end)

    %{id: id, pid: pid}
  end

  test "newer event queued before stall resolves does not drop buffered events", %{id: id, pid: pid} do
    SubscriptionStore.set_enqueue_fn(fn _, _ -> {:error, :timeout} end)
    # Arrival order deliberately differs from ID order within the buffer.
    for n <- [100, 102, 101], do: send(pid, {:event, event(n)})
    assert SubscriptionStore.snapshot(id).last_seen_event_id == 99
    test_pid = self()

    SubscriptionStore.set_enqueue_fn(fn _, ev ->
      send(test_pid, {:delivered, ev.id})
      :ok
    end)

    queue_retry_and_newer(pid, 103)
    assert SubscriptionStore.snapshot(id).last_seen_event_id == 103
    assert delivered_ids() == [100, 101, 102, 103]
  end

  test "re-stall during drain keeps the remaining buffer", %{id: id, pid: pid} do
    SubscriptionStore.set_enqueue_fn(fn _, _ -> {:error, :timeout} end)
    for n <- 100..102, do: send(pid, {:event, event(n)})
    assert SubscriptionStore.snapshot(id).last_seen_event_id == 99
    test_pid = self()

    SubscriptionStore.set_enqueue_fn(fn
      _, %{id: 101} ->
        {:error, :timeout}

      _, ev ->
        send(test_pid, {:delivered, ev.id})
        :ok
    end)

    queue_retry_and_newer(pid, 103)
    assert SubscriptionStore.snapshot(id).last_seen_event_id == 100
    state = :sys.get_state(pid)
    assert state.stall.event_id == 101
    assert Enum.map(state.stalled_buffer, &elem(&1, 0)) == [102, 103]
    assert delivered_ids() == [100]

    SubscriptionStore.set_enqueue_fn(fn _, ev ->
      send(test_pid, {:delivered, ev.id})
      :ok
    end)

    send(pid, {:retry_stalled})
    assert SubscriptionStore.snapshot(id).last_seen_event_id == 103
    assert delivered_ids() == [101, 102, 103]
  end

  defp event(id), do: %{id: id, topic: "ticket.42.branch.push"}

  defp queue_retry_and_newer(pid, id) do
    :ok = :sys.suspend(pid)
    send(pid, {:retry_stalled})
    send(pid, {:event, event(id)})
    :ok = :sys.resume(pid)
  end

  # The synchronous snapshot proves delivery finished before checking the mailbox.
  defp delivered_ids do
    receive do
      {:delivered, id} -> [id | delivered_ids()]
    after
      0 -> []
    end
  end
end
