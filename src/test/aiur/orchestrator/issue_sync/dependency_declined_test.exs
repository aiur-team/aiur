defmodule Aiur.Orchestrator.IssueSync.DependencyDeclinedTest do
  # Global tracker and event doubles require synchronous cases.
  use Aiur.TestSupport

  import Aiur.IssueSyncTestSupport

  alias Aiur.Events.Exchange
  alias Aiur.Events.Publisher
  alias Aiur.Orchestrator.IssueSync
  alias Aiur.Orchestrator.State

  describe "dependency-declined backlog is not capacity-ready work (#2592)" do
    setup do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("system.dispatch.capacity_starved")
      :ok = Exchange.subscribe("system.dispatch.capacity_starved.resolved")
      :ok = Exchange.subscribe("system.fleet.capacity.starved")
      :ok = Exchange.subscribe("system.fleet.capacity.starved.resolved")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      # The live failure shape: a polled todo issue carrying no hydrated
      # `blocked_by`, whose hydrated dependency check already declined dispatch.
      queued = issue("dag-blocked", "todo")
      assert queued.blocked_by == []

      state = %State{
        poll_interval_ms: 5_000,
        max_concurrent_agents: 5,
        effective_concurrent_agents: 2,
        running: running_agents(2),
        dispatch_capacity_sample: %{load: 2.0, target: 1.0, schedulers: 16},
        dispatch_capacity_constraints: [%{kind: :load, detail: "load=24.0 threshold=1.0 schedulers=8"}]
      }

      %{queued: queued, state: state}
    end

    test "stays quiet when every queued ticket is dependency-declined", %{queued: queued, state: state} do
      quiet =
        %{state | dispatch_declines: %{queued.id => :dependency}}
        |> IssueSync.sync_capacity_starvation_alert([queued], 1_000)
        |> IssueSync.sync_fleet_capacity_starved_alert([queued], 1_000)
        |> IssueSync.sync_capacity_starvation_alert([queued], 61_000)
        |> IssueSync.sync_fleet_capacity_starved_alert([queued], 61_000)
        |> IssueSync.sync_capacity_starvation_alert([queued], 121_000)
        |> IssueSync.sync_fleet_capacity_starved_alert([queued], 121_000)

      refute quiet.capacity_starvation.alert_active
      refute quiet.fleet_capacity_starvation.alert_active

      mailbox_barrier()
      refute_received {:event, %{topic: "system.dispatch.capacity_starved"}}
      refute_received {:event, %{topic: "system.fleet.capacity.starved"}}
    end

    test "resolves an active attention once the backlog becomes dependency-declined", %{queued: queued, state: state} do
      alerted =
        state
        |> IssueSync.sync_capacity_starvation_alert([queued], 1_000)
        |> IssueSync.sync_fleet_capacity_starved_alert([queued], 1_000)
        |> IssueSync.sync_capacity_starvation_alert([queued], 61_000)
        |> IssueSync.sync_fleet_capacity_starved_alert([queued], 61_000)

      assert alerted.capacity_starvation.alert_active
      assert alerted.fleet_capacity_starvation.alert_active
      assert_received {:event, %{topic: "system.dispatch.capacity_starved"}}
      assert_received {:event, %{topic: "system.fleet.capacity.starved"}}

      resolved =
        %{alerted | dispatch_declines: %{queued.id => :dependency}}
        |> IssueSync.sync_capacity_starvation_alert([queued], 122_000)
        |> IssueSync.sync_fleet_capacity_starved_alert([queued], 122_000)

      refute resolved.capacity_starvation.alert_active
      refute resolved.fleet_capacity_starvation.alert_active
      assert_received {:event, %{topic: "system.dispatch.capacity_starved.resolved"}}
      assert_received {:event, %{topic: "system.fleet.capacity.starved.resolved"}}
    end

    test "a hydration-failed decline is still ready work and still alerts", %{queued: queued, state: state} do
      alerted =
        %{state | dispatch_declines: %{queued.id => :dependency_hydration_failed}}
        |> IssueSync.sync_capacity_starvation_alert([queued], 1_000)
        |> IssueSync.sync_fleet_capacity_starved_alert([queued], 1_000)
        |> IssueSync.sync_capacity_starvation_alert([queued], 61_000)
        |> IssueSync.sync_fleet_capacity_starved_alert([queued], 61_000)

      assert alerted.capacity_starvation.alert_active
      assert alerted.fleet_capacity_starvation.alert_active
      assert_received {:event, %{topic: "system.dispatch.capacity_starved"} = event}
      assert event["reason"] =~ "Ready tickets=1"
      assert_received {:event, %{topic: "system.fleet.capacity.starved"}}
    end
  end
end
