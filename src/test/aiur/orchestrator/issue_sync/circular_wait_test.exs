defmodule Aiur.Orchestrator.IssueSync.CircularWaitTest do
  # Global tracker and event doubles require synchronous cases.
  use Aiur.TestSupport

  import Aiur.IssueSyncTestSupport

  alias Aiur.Events.Exchange
  alias Aiur.Events.Publisher
  alias Aiur.Orchestrator.IssueSync
  alias Aiur.Orchestrator.State

  test "alerts when parked agents wait on an undispatched queued keystone" do
    Publisher.set_tracked_fn(fn _ -> true end)
    keystone = issue("keystone", "todo")
    topic = "ticket.#{keystone.identifier}.agent.attention.dependency-circular-wait"
    resolved_topic = topic <> ".resolved"
    :ok = Exchange.subscribe(topic)
    :ok = Exchange.subscribe(resolved_topic)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    state = %State{
      max_concurrent_agents: 1,
      effective_concurrent_agents: 1,
      running: %{
        "blocked-one" => dependency_paused_entry(keystone.identifier),
        "blocked-two" => dependency_paused_entry(keystone.identifier),
        "operator-pause" => %{control: %{status: :paused}, paused_reason: :operator_pause}
      }
    }

    waiting = IssueSync.sync_dependency_circular_wait_alert(state, [keystone], 1_000)
    refute waiting.dependency_circular_wait[keystone.id].alerted?
    mailbox_barrier()
    refute_received {:event, %{topic: ^topic}}

    alerted = IssueSync.sync_dependency_circular_wait_alert(waiting, [keystone], 61_000)
    assert alerted.dependency_circular_wait[keystone.id].alerted?

    assert_received {:event, %{topic: ^topic} = event}
    assert event["needs_attention"] == true
    assert event["reason"] =~ keystone.identifier
    assert event["reason"] =~ "2 parked agent(s)"

    repeated = IssueSync.sync_dependency_circular_wait_alert(alerted, [keystone], 122_000)
    assert repeated == alerted
    mailbox_barrier()
    refute_received {:event, %{topic: ^topic}}

    held = %{repeated | capacity_hold: %{signal: :load}}
    assert IssueSync.sync_dependency_circular_wait_alert(held, [keystone], 123_000) == held
    mailbox_barrier()
    refute_received {:event, %{topic: ^resolved_topic}}

    resumed = %{held | capacity_hold: nil}
    assert IssueSync.sync_dependency_circular_wait_alert(resumed, [keystone], 124_000).dependency_circular_wait == repeated.dependency_circular_wait
    mailbox_barrier()
    refute_received {:event, %{topic: ^topic}}

    dispatched = %{
      resumed
      | running:
          resumed.running
          |> Map.delete("operator-pause")
          |> Map.put(keystone.id, %{control: %{status: :working}, issue: keystone})
    }

    recovered = IssueSync.sync_dependency_circular_wait_alert(dispatched, [keystone], 123_000)
    assert recovered.dependency_circular_wait == %{}
    assert_received {:event, %{topic: ^resolved_topic}}
  end

  test "does not report circular waits while dispatch is intentionally held" do
    Publisher.set_tracked_fn(fn _ -> true end)
    keystone = issue("held-keystone", "todo")
    topic = "ticket.#{keystone.identifier}.agent.attention.dependency-circular-wait"
    :ok = Exchange.subscribe(topic)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    blocked = %{
      "blocked" => dependency_paused_entry(keystone.identifier)
    }

    for state <- [
          %State{running: blocked, globally_paused: true},
          %State{running: blocked, capacity_hold: %{signal: :load}},
          %State{running: blocked, prewarm_hold_ticks: 1}
        ] do
      assert IssueSync.sync_dependency_circular_wait_alert(state, [keystone], 61_000).dependency_circular_wait == %{}
    end

    mailbox_barrier()
    refute_received {:event, %{topic: ^topic}}
  end
end
