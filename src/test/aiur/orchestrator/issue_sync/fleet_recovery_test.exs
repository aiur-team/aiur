defmodule Aiur.Orchestrator.IssueSync.FleetRecoveryTest do
  # Global tracker and event doubles require synchronous cases.
  use Aiur.TestSupport

  import Aiur.IssueSyncTestSupport

  alias Aiur.Events.Exchange
  alias Aiur.Events.Publisher
  alias Aiur.Orchestrator.IssueSync
  alias Aiur.Orchestrator.State

  test "resolves and rearms fleet starvation after capacity recovers" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.fleet.capacity.starved")
    :ok = Exchange.subscribe("system.fleet.capacity.starved.resolved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    ready = for id <- 1..8, do: issue("rearm-#{id}", "todo")

    state = %State{
      max_concurrent_agents: 20,
      effective_concurrent_agents: 20,
      running: running_agents(3),
      dispatch_capacity_sample: %{load: 0.7, target: 1.0, schedulers: 16}
    }

    alerted =
      state
      |> IssueSync.sync_fleet_capacity_starved_alert(ready, 1_000)
      |> IssueSync.sync_fleet_capacity_starved_alert(ready, 61_000)

    assert_received {:event, %{topic: "system.fleet.capacity.starved"}}

    recovered = IssueSync.sync_fleet_capacity_starved_alert(alerted, [], 62_000)
    assert recovered.fleet_capacity_starvation == %{since_ms: nil, alert_active: false, effective_cap: nil}
    assert_received {:event, %{topic: "system.fleet.capacity.starved.resolved"}}

    rearmed = IssueSync.sync_fleet_capacity_starved_alert(recovered, ready, 100_000)
    _ = IssueSync.sync_fleet_capacity_starved_alert(rearmed, ready, 160_000)
    assert_received {:event, %{topic: "system.fleet.capacity.starved"}}
  end

  test "does not report deliberate global dispatch pauses as starvation" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.fleet.capacity.starved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    ready = for id <- 1..8, do: issue("paused-#{id}", "todo")

    state = %State{
      globally_paused: true,
      max_concurrent_agents: 20,
      effective_concurrent_agents: 20,
      running: running_agents(3),
      dispatch_capacity_sample: %{load: 0.7, target: 1.0, schedulers: 16}
    }

    _ = IssueSync.sync_fleet_capacity_starved_alert(state, ready, 61_000)
    mailbox_barrier()
    refute_received {:event, %{topic: "system.fleet.capacity.starved"}}
  end

  test "does not report capacity starvation when every awaiting-dispatch ticket is blocked on an operator decision" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.fleet.capacity.starved")
    :ok = Exchange.subscribe("system.dispatch.capacity_starved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    ready = for id <- 1..3, do: issue("decision-#{id}", "todo")
    blocked = MapSet.new(Enum.map(ready, & &1.id))

    # Fully ramped and at the ceiling with a load gate, which would normally be
    # reported as starvation — but every awaiting-dispatch ticket is blocked on
    # an open operator Command, and no amount of capacity can start it (#2447).
    state = %State{
      max_concurrent_agents: 16,
      effective_concurrent_agents: 16,
      running: running_agents(16),
      blocked_ticket_ids: blocked,
      dispatch_capacity_constraints: [%{kind: :load, detail: "load=24.0 threshold=1.0 schedulers=8"}],
      dispatch_capacity_sample: %{load: 17.0, target: 1.0, schedulers: 16}
    }

    state
    |> IssueSync.sync_capacity_starvation_alert(ready, 1_000)
    |> IssueSync.sync_capacity_starvation_alert(ready, 61_000)
    |> IssueSync.sync_fleet_capacity_starved_alert(ready, 1_000)
    |> IssueSync.sync_fleet_capacity_starved_alert(ready, 61_000)

    mailbox_barrier()
    refute_received {:event, %{topic: "system.fleet.capacity.starved"}}
    refute_received {:event, %{topic: "system.dispatch.capacity_starved"}}
  end

  test "still alerts when a load gate holds while dispatchable unblocked work is queued" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.fleet.capacity.starved")
    :ok = Exchange.subscribe("system.dispatch.capacity_starved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    ready = for id <- 1..8, do: issue("genuine-#{id}", "todo")

    # The guard against blanket suppression: a resource gate holding while
    # dispatchable, unblocked work is queued must still raise both alerts.
    state = %State{
      max_concurrent_agents: 20,
      effective_concurrent_agents: 4,
      running: running_agents(4),
      capacity_hold: %{signal: :load},
      dispatch_capacity_constraints: [%{kind: :load, detail: "load=24.0 threshold=1.0 schedulers=8"}],
      dispatch_capacity_sample: %{load: 17.0, target: 1.0, schedulers: 16}
    }

    state
    |> IssueSync.sync_capacity_starvation_alert(ready, 1_000)
    |> IssueSync.sync_capacity_starvation_alert(ready, 61_000)
    |> IssueSync.sync_fleet_capacity_starved_alert(ready, 1_000)
    |> IssueSync.sync_fleet_capacity_starved_alert(ready, 61_000)

    assert_received {:event, %{topic: "system.dispatch.capacity_starved"} = dispatch_event}
    assert dispatch_event["reason"] =~ "load gate"
    assert_received {:event, %{topic: "system.fleet.capacity.starved"} = fleet_event}
    assert fleet_event["reason"] =~ "binding constraint=load gate"
  end
end
