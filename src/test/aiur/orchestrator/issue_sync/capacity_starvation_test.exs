defmodule Aiur.Orchestrator.IssueSync.CapacityStarvationTest do
  # Global tracker and event doubles require synchronous cases.
  use Aiur.TestSupport

  import Aiur.IssueSyncTestSupport

  alias Aiur.Events.Exchange
  alias Aiur.Events.Publisher
  alias Aiur.Orchestrator.IssueSync
  alias Aiur.Orchestrator.State
  alias Aiur.Workflow

  test "alerts once with observed dispatch constraints while ready work is held" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.dispatch.capacity_starved")
    :ok = Exchange.subscribe("system.dispatch.capacity_starved.resolved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    ready = issue("capacity", "todo")

    state = %State{
      max_concurrent_agents: 4,
      effective_concurrent_agents: 4,
      dispatch_capacity_constraints: [
        %{kind: :load_envelope, detail: "effective_cap=4 configured_cap=4"},
        %{kind: :memory, detail: "available_mb=512 threshold_mb=2048"},
        %{kind: :fd, detail: "available=2 limit=1024"},
        %{kind: :load, detail: "load=24.0 threshold=1.0 schedulers=8"},
        %{kind: :build, detail: "prewarm=building"}
      ]
    }

    waiting = IssueSync.sync_capacity_starvation_alert(state, [ready], 1_000)

    assert waiting.capacity_starvation == %{
             since_ms: %{
               "build" => 1_000,
               "fd" => 1_000,
               "load" => 1_000,
               "load-envelope" => 1_000,
               "memory" => 1_000
             },
             alert_active: false,
             signature: [
               "build",
               "fd",
               "load",
               "load-envelope",
               "memory"
             ],
             alerted: []
           }

    alerted = IssueSync.sync_capacity_starvation_alert(waiting, [ready], 61_000)

    assert alerted.capacity_starvation == %{
             since_ms: waiting.capacity_starvation.since_ms,
             alert_active: true,
             signature: waiting.capacity_starvation.signature,
             alerted: waiting.capacity_starvation.signature
           }

    assert_received {:event, %{topic: "system.dispatch.capacity_starved"} = event}
    assert event["reason"] =~ "Ready tickets=1"
    assert event["reason"] =~ "effective cap=4, configured cap=4"
    assert event["reason"] =~ "adaptive envelope limit"
    assert event["reason"] =~ "memory gate"
    assert event["reason"] =~ "FD gate"
    assert event["reason"] =~ "load gate"
    assert event["reason"] =~ "prewarm build"
    refute event["reason"] =~ "cold-start"

    assert IssueSync.sync_capacity_starvation_alert(alerted, [ready], 122_000) == alerted
    mailbox_barrier()
    refute_received {:event, %{topic: "system.dispatch.capacity_starved"}}

    recovered = IssueSync.sync_capacity_starvation_alert(alerted, [], 122_000)
    assert recovered.capacity_starvation == %{since_ms: %{}, alert_active: false, signature: [], alerted: []}
    assert_received {:event, %{topic: "system.dispatch.capacity_starved.resolved"}}

    rearmed = IssueSync.sync_capacity_starvation_alert(recovered, [ready], 200_000)
    _ = IssueSync.sync_capacity_starvation_alert(rearmed, [ready], 260_000)
    assert_received {:event, %{topic: "system.dispatch.capacity_starved"}}
  end

  test "does not count an issue claimed in the same dispatch cycle as ready work" do
    ready = issue("claimed", "todo")

    state = %State{
      max_concurrent_agents: 4,
      effective_concurrent_agents: 1,
      claimed: MapSet.new([ready.id]),
      dispatch_capacity_constraints: [%{kind: :load_envelope, detail: "effective_cap=1 configured_cap=4"}]
    }

    assert IssueSync.sync_capacity_starvation_alert(state, [ready], 61_000).capacity_starvation == %{
             since_ms: %{},
             alert_active: false,
             signature: [],
             alerted: []
           }
  end

  test "resets the starvation timer when the dispatch constraint changes" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.dispatch.capacity_starved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    ready = issue("constraint-change", "todo")

    waiting =
      IssueSync.sync_capacity_starvation_alert(
        %State{dispatch_capacity_constraints: [%{kind: :load, detail: "load=10"}]},
        [ready],
        1_000
      )

    changed = %{
      waiting
      | dispatch_capacity_constraints: [%{kind: :memory, detail: "available_mb=512 threshold_mb=2048"}]
    }

    reset = IssueSync.sync_capacity_starvation_alert(changed, [ready], 61_000)
    assert reset.capacity_starvation.since_ms == %{"memory" => 61_000}
    refute reset.capacity_starvation.alert_active
    mailbox_barrier()
    refute_received {:event, %{topic: "system.dispatch.capacity_starved"}}

    alerted = IssueSync.sync_capacity_starvation_alert(reset, [ready], 121_000)
    assert alerted.capacity_starvation.alert_active
    assert_received {:event, %{topic: "system.dispatch.capacity_starved"} = event}
    assert event["reason"] =~ "memory gate"
  end

  test "keeps the starvation timer through changing samples of one gate" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.dispatch.capacity_starved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    ready = issue("load-samples", "todo")

    waiting =
      IssueSync.sync_capacity_starvation_alert(
        %State{dispatch_capacity_constraints: [%{kind: :load, detail: "load=8.1"}]},
        [ready],
        1_000
      )

    sampled = %{waiting | dispatch_capacity_constraints: [%{kind: :load, detail: "load=9.7"}]}
    alerted = IssueSync.sync_capacity_starvation_alert(sampled, [ready], 61_000)

    assert alerted.capacity_starvation.alert_active
    assert alerted.capacity_starvation.signature == ["load"]
    assert_received {:event, %{topic: "system.dispatch.capacity_starved"} = event}
    assert event["reason"] =~ "load=9.7"
  end

  test "resets the starvation timer when a budget latch moves to another ticket" do
    first = issue("budget-first", "todo")
    second = issue("budget-second", "todo")

    waiting =
      IssueSync.sync_capacity_starvation_alert(
        %State{dispatch_recovery: %{codex_thrash_budget: %{first.id => %{tripped: :lifetime, lifetime: 20}}}},
        [first],
        1_000
      )

    moved = %{
      waiting
      | dispatch_recovery: %{codex_thrash_budget: %{second.id => %{tripped: :lifetime, lifetime: 20}}}
    }

    reset = IssueSync.sync_capacity_starvation_alert(moved, [second], 61_000)

    assert reset.capacity_starvation == %{
             since_ms: %{"budget:lifetime:#{second.id}" => 61_000},
             alert_active: false,
             signature: ["budget:lifetime:#{second.id}"],
             alerted: []
           }
  end

  test "includes budget constraints for ready work in every active state" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.dispatch.capacity_starved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Rework"]
    )

    ready = issue("budget-rework", "rework")

    state = %State{
      max_concurrent_agents: 4,
      effective_concurrent_agents: 4,
      dispatch_recovery: %{
        workspace_ownership: %{waits: %{}, ready: %{}},
        codex_thrash_budget: %{ready.id => %{tripped: :lifetime, lifetime: 20}}
      }
    }

    waiting = IssueSync.sync_capacity_starvation_alert(state, [ready], 1_000)
    alerted = IssueSync.sync_capacity_starvation_alert(waiting, [ready], 61_000)

    assert alerted.capacity_starvation.alert_active
    assert_received {:event, %{topic: "system.dispatch.capacity_starved"} = event}
    assert event["reason"] =~ "budget latch (lifetime=20)"
  end
end
