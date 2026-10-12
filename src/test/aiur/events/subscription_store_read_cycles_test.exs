defmodule Aiur.Events.SubscriptionStoreReadCyclesTest do
  use Aiur.TestSupport

  alias Aiur.Events.{BranchRefStore, SubscriptionStore, SubscriptionStoreRegistry}
  alias Aiur.Orchestrator.AutoSubscriptions

  setup do
    :ok = Aiur.TestSupport.ensure_subscription_store_supervisor_running()
    orchestrator = Process.whereis(Orchestrator)
    original = :sys.get_state(orchestrator)
    blockee = "cycle-#{System.unique_integer([:positive])}"
    blocker = to_string(System.unique_integer([:positive]))
    :ok = AutoSubscriptions.subscribe_for_declared_blocker(blockee, blocker)
    [{store, _}] = Registry.lookup(SubscriptionStoreRegistry, blockee)

    on_exit(fn ->
      SubscriptionStore.set_enqueue_fn(nil)
      SubscriptionStore.stop(blockee)
      SubscriptionStore.stop(blocker)
      :sys.replace_state(orchestrator, fn state -> %{state | running: original.running, queue_store: original.queue_store} end)
    end)

    {:ok, orchestrator: orchestrator, blockee: blockee, blocker: blocker, store: store}
  end

  test "blocker-critical claim does not call a delivering store", ctx do
    event = event(ctx, "pr.merged")
    :ok = GenServer.call(ctx.orchestrator, {:enqueue_event_digest, ctx.blockee, event})
    owner = self()

    SubscriptionStore.set_enqueue_fn(fn identifier, _event ->
      result = GenServer.call(ctx.orchestrator, {:claim_blocker_critical_events_digest, identifier}, 1_000)
      send(owner, {:claimed, result})
      :ok
    end)

    deliver_and_refute_snapshot(ctx, event)
    assert_receive {:claimed, {:ok, %{body: %{urgent: true}, target_issue_identifier: identifier}}}, 0
    assert identifier == ctx.blockee
  end

  test "unblock routing reads bindings while the store waits for the Orchestrator", ctx do
    ref = "refs/heads/aiur/#{ctx.blocker}-cycle"
    sha = String.duplicate("a", 40)
    :ok = BranchRefStore.record(ref, sha)
    issue = %Aiur.Issue{id: ctx.blockee, identifier: ctx.blockee, state: "in-progress"}

    entry = %{
      identifier: ctx.blockee,
      issue: issue,
      pid: self(),
      control: %{status: :working},
      paused_reason: :blocker_dependency,
      blocker_pause_generation: 1,
      blocker_pause: %{blocker_identifier: ctx.blocker, generation: 1}
    }

    :sys.replace_state(ctx.orchestrator, fn state -> %{state | running: %{issue.id => entry}} end)
    event = Map.put(event(ctx, "agent.unblocked"), :payload, %{ref: ref, sha: sha})

    SubscriptionStore.set_enqueue_fn(fn _identifier, event ->
      # Routing precedes status from the same sender while the store waits.
      send(ctx.orchestrator, {:event, event})
      {:ok, _} = Orchestrator.status(ctx.orchestrator, 1_000)
      :ok
    end)

    deliver_and_refute_snapshot(ctx, event)
    hint = :sys.get_state(ctx.orchestrator).running[issue.id].pending_auto_resume
    assert hint.blocker_identifier == ctx.blocker
    assert hint.topic == event.topic
    assert hint.unblock_key == event.topic <> ":" <> sha
    assert hint.pause_generation == 1
  end

  test "Registry bindings track reason-scoped removals and store restart", ctx do
    topic = "ticket.#{ctx.blocker}.agent.unblocked"
    assert Enum.any?(SubscriptionStore.subscriptions(ctx.blockee), &(&1["topic"] == topic))
    :ok = SubscriptionStore.remove_subscription(ctx.blockee, topic, "manual:agent")
    assert Enum.any?(SubscriptionStore.subscriptions(ctx.blockee), &(&1["topic"] == topic))
    :ok = SubscriptionStore.remove_subscription(ctx.blockee, topic, "blocker:auto")
    refute Enum.any?(SubscriptionStore.subscriptions(ctx.blockee), &(&1["topic"] == topic))
    expected = SubscriptionStore.snapshot(ctx.blockee).subscribed_to
    :ok = SubscriptionStore.stop(ctx.blockee)
    assert SubscriptionStore.subscriptions(ctx.blockee) == []
    :ok = SubscriptionStore.attach(ctx.blockee)
    assert SubscriptionStore.subscriptions(ctx.blockee) == expected
  end

  defp event(ctx, suffix) do
    cursor = :sys.get_state(ctx.store).last_seen_event_id || 0
    %{id: cursor + 1_000_000_000 + System.unique_integer([:positive]), topic: "ticket.#{ctx.blocker}.#{suffix}"}
  end

  defp deliver_and_refute_snapshot(ctx, event) do
    :erlang.trace(ctx.store, true, [:receive])
    send(ctx.store, {:event, event})
    state = :sys.get_state(ctx.store)
    :erlang.trace(ctx.store, false, [:receive])
    ref = :erlang.trace_delivered(ctx.store)
    receive_barrier({:trace_delivered, _, ^ref})
    assert state.stall == nil
    assert state.last_seen_event_id == event.id
    store = ctx.store
    refute_received {:trace, ^store, :receive, {:"$gen_call", _from, :snapshot}}
  end
end
