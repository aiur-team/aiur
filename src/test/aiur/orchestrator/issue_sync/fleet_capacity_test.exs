defmodule Aiur.Orchestrator.IssueSync.FleetCapacityTest do
  # Global tracker and event doubles require synchronous cases.
  use Aiur.TestSupport

  import Aiur.IssueSyncTestSupport

  alias Aiur.Events.Exchange
  alias Aiur.Events.Publisher
  alias Aiur.Orchestrator.IssueSync
  alias Aiur.Orchestrator.State
  alias Aiur.Workflow

  test "emits a fleet starvation alert after one configured poll interval" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.fleet.capacity.starved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    ready = [issue("ready-1", "todo")]

    state = %State{
      poll_interval_ms: 5_000,
      max_concurrent_agents: 16,
      effective_concurrent_agents: 16,
      running: running_agents(15),
      dispatch_capacity_sample: %{load: 15.0, target: 1.0, schedulers: 16}
    }

    waiting = IssueSync.sync_fleet_capacity_starved_alert(state, ready, 1_000)
    refute waiting.fleet_capacity_starvation.alert_active
    mailbox_barrier()
    refute_received {:event, %{topic: "system.fleet.capacity.starved"}}

    almost_due = IssueSync.sync_fleet_capacity_starved_alert(waiting, ready, 5_999)
    refute almost_due.fleet_capacity_starvation.alert_active
    mailbox_barrier()
    refute_received {:event, %{topic: "system.fleet.capacity.starved"}}

    alerted = IssueSync.sync_fleet_capacity_starved_alert(almost_due, ready, 6_000)
    assert alerted.fleet_capacity_starvation.alert_active

    assert_received {:event, %{topic: "system.fleet.capacity.starved"} = event}
    assert event["needs_attention"] == true
    assert event["reason"] =~ "Ready tickets=1, live agents=15"
    assert event["reason"] =~ "load=15.0/16.0"
    assert event["reason"] =~ "effective cap=16, configured cap=16"
    assert event["reason"] =~ "binding constraint=no binding constraint identified"
  end

  test "does not alert while a low-load fleet is normally ramping its envelope" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.fleet.capacity.starved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    ready = for id <- 1..8, do: issue("ramp-#{id}", "todo")
    sample = %{load: 0.7, target: 1.0, schedulers: 16}

    starting = %State{max_concurrent_agents: 20, effective_concurrent_agents: 1, running: running_agents(1), dispatch_capacity_sample: sample}
    first = IssueSync.sync_fleet_capacity_starved_alert(starting, ready, 1_000)

    second =
      %{first | effective_concurrent_agents: 2}
      |> IssueSync.sync_fleet_capacity_starved_alert(ready, 61_000)

    _third =
      %{second | effective_concurrent_agents: 3}
      |> IssueSync.sync_fleet_capacity_starved_alert(ready, 121_000)

    mailbox_barrier()
    refute_received {:event, %{topic: "system.fleet.capacity.starved"}}
  end

  test "reports a zero-agent ready fleet after one poll interval with no identified binding constraint" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.fleet.capacity.starved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    ready = [issue("orphan-released", "todo")]

    state = %State{
      max_concurrent_agents: 16,
      effective_concurrent_agents: 16,
      poll_interval_ms: 30_000,
      running: %{},
      dispatch_capacity_sample: %{load: 8.0, target: 1.0, schedulers: 16}
    }

    waiting = IssueSync.sync_fleet_capacity_starved_alert(state, ready, 1_000)
    refute_receive {:event, %{topic: "system.fleet.capacity.starved"}}, 100

    _alerted = IssueSync.sync_fleet_capacity_starved_alert(waiting, ready, 31_000)

    assert_receive {:event, %{topic: "system.fleet.capacity.starved"} = event}, 500
    assert event["reason"] =~ "Ready tickets=1, live agents=0"
    assert event["reason"] =~ "binding constraint=no binding constraint identified"
  end

  test "does not alert while a fleet sits at its envelope during a below-target ramp" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.fleet.capacity.starved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    ready = for id <- 1..8, do: issue("envelope-ramp-#{id}", "todo")

    # A fleet at 2 of 16 with an envelope of 2 is at capacity, not starved:
    # the below-target envelope is mid-ramp and widens on the next sample, so
    # the fleet filling to its envelope is the intended ramp (#2447).
    state = %State{
      max_concurrent_agents: 20,
      effective_concurrent_agents: 3,
      running: running_agents(3),
      dispatch_capacity_sample: %{load: 0.7, target: 1.0, schedulers: 16}
    }

    state
    |> IssueSync.sync_fleet_capacity_starved_alert(ready, 1_000)
    |> IssueSync.sync_fleet_capacity_starved_alert(ready, 61_000)
    |> IssueSync.sync_fleet_capacity_starved_alert(ready, 121_000)

    mailbox_barrier()
    refute_received {:event, %{topic: "system.fleet.capacity.starved"}}
  end

  test "reports a load envelope holding under load as the binding constraint" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.fleet.capacity.starved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    ready = for id <- 1..8, do: issue("envelope-#{id}", "todo")

    # Above-target load means the envelope is not ramping — it is the binding
    # constraint holding capacity below the ceiling while ready work queues.
    state = %State{
      max_concurrent_agents: 20,
      effective_concurrent_agents: 3,
      running: running_agents(3),
      dispatch_capacity_sample: %{load: 17.0, target: 1.0, schedulers: 16}
    }

    state
    |> IssueSync.sync_fleet_capacity_starved_alert(ready, 1_000)
    |> IssueSync.sync_fleet_capacity_starved_alert(ready, 61_000)

    assert_received {:event, %{topic: "system.fleet.capacity.starved"} = event}
    assert event["reason"] =~ "binding constraint=adaptive envelope (effective cap=3)"
  end

  test "reports a per-state ceiling as the binding constraint" do
    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents_by_state: %{"todo" => 3})
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.fleet.capacity.starved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    ready = for id <- 1..8, do: issue("state-limit-#{id}", "todo")

    state = %State{
      max_concurrent_agents: 20,
      effective_concurrent_agents: 20,
      running: running_agents(3, "todo"),
      dispatch_capacity_sample: %{load: 0.7, target: 1.0, schedulers: 16}
    }

    state
    |> IssueSync.sync_fleet_capacity_starved_alert(ready, 1_000)
    |> IssueSync.sync_fleet_capacity_starved_alert(ready, 61_000)

    assert_received {:event, %{topic: "system.fleet.capacity.starved"} = event}
    assert event["reason"] =~ "binding constraint=per-state limit (todo=3/3)"
  end

  test "reports every saturated per-state ceiling" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_active_states: ["todo", "in-progress"],
      max_concurrent_agents_by_state: %{"todo" => 1, "in-progress" => 1}
    )

    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.fleet.capacity.starved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    ready =
      for state <- ["todo", "in-progress"], id <- 1..4, do: issue("#{state}-limit-#{id}", state)

    running = %{
      "live-todo" => %{issue: issue("live-todo", "todo")},
      "live-in-progress" => %{issue: issue("live-in-progress", "in-progress")}
    }

    state = %State{
      max_concurrent_agents: 20,
      effective_concurrent_agents: 20,
      running: running,
      dispatch_capacity_sample: %{load: 0.7, target: 1.0, schedulers: 16}
    }

    state
    |> IssueSync.sync_fleet_capacity_starved_alert(ready, 1_000)
    |> IssueSync.sync_fleet_capacity_starved_alert(ready, 61_000)

    assert_received {:event, %{topic: "system.fleet.capacity.starved"} = event}
    assert event["reason"] =~ "per-state limit (in-progress=1/1)"
    assert event["reason"] =~ "per-state limit (todo=1/1)"
  end

  test "reports the current run-queue hold as the binding constraint" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.fleet.capacity.starved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    ready = for id <- 1..8, do: issue("run-queue-#{id}", "todo")

    state = %State{
      max_concurrent_agents: 20,
      effective_concurrent_agents: 20,
      running: running_agents(3),
      capacity_hold: %{signal: :run_queue},
      dispatch_capacity_constraints: [%{kind: :run_queue, detail: "runnable=8 threshold=4"}],
      dispatch_capacity_sample: %{load: 0.7, target: 1.0, schedulers: 16}
    }

    state
    |> IssueSync.sync_fleet_capacity_starved_alert(ready, 1_000)
    |> IssueSync.sync_fleet_capacity_starved_alert(ready, 61_000)

    assert_received {:event, %{topic: "system.fleet.capacity.starved"} = event}
    assert event["reason"] =~ "binding constraint=run-queue gate (runnable=8 threshold=4)"
  end

  test "reports all-provider dispatch authorization denials as the binding constraint" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.fleet.capacity.starved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    ready = for id <- 1..8, do: issue("limited-#{id}", "todo")

    state = %State{
      max_concurrent_agents: 20,
      effective_concurrent_agents: 20,
      running: running_agents(3),
      model_fallback_waiting: MapSet.new(Enum.map(ready, & &1.id)),
      dispatch_capacity_sample: %{load: 0.7, target: 1.0, schedulers: 16}
    }

    state
    |> IssueSync.sync_fleet_capacity_starved_alert(ready, 1_000)
    |> IssueSync.sync_fleet_capacity_starved_alert(ready, 61_000)

    assert_received {:event, %{topic: "system.fleet.capacity.starved"} = event}

    assert event["reason"] =~
             "binding constraint=dispatch authorization denials (all fallback backends usage-limited for 8 ready ticket(s))"
  end
end
