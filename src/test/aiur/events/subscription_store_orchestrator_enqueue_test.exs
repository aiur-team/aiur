defmodule Aiur.Events.SubscriptionStoreOrchestratorEnqueueTest do
  @moduledoc """
  #3749: a ticket's SubscriptionStore delivers each event to the live
  Orchestrator with a synchronous call. To classify the digest, the Orchestrator
  needs the ticket's `blocker:auto` bindings, and it read them with
  `SubscriptionStore.snapshot/1`, which is a call back into the same store. The
  store was still blocked in its own call, so the Orchestrator was held until
  that call timed out at 1 s. Every control query queued behind it (a 1 s
  `Orchestrator.status/2` in `ResumeControlRegressionTest` failed this way on
  coverage CI), and the store marked the delivery as stalled although the
  Orchestrator had queued it.
  """

  use Aiur.TestSupport

  alias Aiur.Events.{SubscriptionStore, SubscriptionStoreRegistry}
  alias Aiur.Orchestrator.AutoSubscriptions

  setup do
    :ok = Aiur.TestSupport.ensure_subscription_store_supervisor_running()
    SubscriptionStore.set_enqueue_fn(nil)

    pid = Process.whereis(Orchestrator)
    original_queue_store = :sys.get_state(pid).queue_store

    on_exit(fn ->
      if Process.alive?(pid) do
        :sys.replace_state(pid, fn state -> %{state | queue_store: original_queue_store} end)
      end
    end)

    {:ok, orchestrator: pid}
  end

  test "the store's own delivery is classified without a snapshot read back into the store", %{orchestrator: pid} do
    blockee = "blockee-#{System.unique_integer([:positive])}"
    blocker = "blocker-#{System.unique_integer([:positive])}"
    :ok = AutoSubscriptions.subscribe_for_declared_blocker(blockee, blocker)
    on_exit(fn -> SubscriptionStore.stop(blockee) end)
    on_exit(fn -> SubscriptionStore.stop(blocker) end)

    [{store, _count}] = Registry.lookup(SubscriptionStoreRegistry, blockee)
    # The Orchestrator drops an event whose id is already queued, and the
    # shared Orchestrator holds items from earlier cases, so the id is unique.
    cursor = :sys.get_state(store).last_seen_event_id || 0
    event = %{id: cursor + 1_000_000_000 + System.unique_integer([:positive]), topic: "ticket.#{blocker}.pr.merged"}

    :erlang.trace(store, true, [:receive])
    on_exit(fn -> if Process.alive?(store), do: :erlang.trace(store, false, [:receive]) end)

    send(store, {:event, event})

    # The store answers this only after it handled the event, which includes
    # its whole call to the Orchestrator.
    store_state = :sys.get_state(store)
    :erlang.trace(store, false, [:receive])

    # The store saw its call succeed, so it holds no stalled delivery.
    assert store_state.stall == nil

    # The bindings travel with the request, so the blocker is still found.
    assert %{body: %{urgent: true}} = queued_digest(:sys.get_state(pid), blockee)

    # The deadlock itself: the Orchestrator never called back into the store
    # that was waiting on it.
    refute_received {:trace, ^store, :receive, {:"$gen_call", _from, :snapshot}}
  end

  defp queued_digest(state, identifier) do
    state.queue_store.items
    |> Map.values()
    |> Enum.find(&(&1.target_issue_identifier == identifier and &1.event_type == :events_digest))
  end
end
