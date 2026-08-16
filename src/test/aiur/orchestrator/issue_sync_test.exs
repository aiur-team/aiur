defmodule Aiur.Orchestrator.IssueSyncTest do
  use Aiur.TestSupport

  alias Aiur.{AgentQueueStore, AlertFeed, AlertLedger, Config, Issue, TrackerIdentity, Workflow}
  alias Aiur.Events.{Exchange, Publisher, SubscriptionStore}
  alias Aiur.Orchestrator.{IssueSync, PushRouting, State}

  test "ignores a non-list poll result" do
    state = %State{last_polled_issues: %{"42" => %{id: "42"}}}

    assert IssueSync.sync_polled_issue_state(state, :invalid) == state
  end

  test "resumes a dependency-paused agent when its recorded blocker becomes terminal" do
    Publisher.set_tracked_fn(fn _ -> true end)

    blockee_identifier = "its-everdred/aiur#blockee"
    pause_topic = "ticket.#{blockee_identifier}.agent.attention.paused-blocker_dependency"
    resolved_pause_topic = "#{pause_topic}.resolved"
    cleared_topic = "ticket.#{blockee_identifier}.agent.dependency_cleared"
    :ok = Exchange.subscribe(pause_topic)
    :ok = Exchange.subscribe(resolved_pause_topic)
    :ok = Exchange.subscribe(cleared_topic)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    parent = self()
    agent = spawn_link(fn -> control_agent(parent) end)
    assert_receive {:agent_started, ^agent}

    blocker = %{id: "blocker", identifier: "its-everdred/aiur#blocker", state: "in-progress"}
    previous = %{issue("blockee", "in-progress") | blocked_by: [blocker]}
    current = %{previous | blocked_by: [%{blocker | state: "done"}]}

    entry = %{
      pid: agent,
      identifier: blockee_identifier,
      issue: previous,
      control: %{status: :paused, can_interrupt: true},
      paused_reason: :blocker_dependency,
      blocker_pause_generation: 1,
      blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
    }

    resumed =
      IssueSync.sync_polled_issue_state(
        %State{last_polled_issues: %{previous.id => previous}, running: %{previous.id => entry}, max_concurrent_agents: 2},
        [current],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_receive {:resume_agent, _request_id}
    assert_receive {:event, %{topic: ^cleared_topic} = alert}, 2_000
    assert alert["reason"] =~ "Blocker its-everdred/aiur#blocker reached terminal state done"
    assert alert["needs_attention"] in [false, nil]
    assert get_in(resumed.running, [previous.id, :control, :status]) == :working
    refute Map.has_key?(resumed.running[previous.id], :paused_reason)
    assert_receive {:event, %{topic: ^resolved_pause_topic}}, 2_000
    refute_receive {:event, %{topic: ^pause_topic}}, 200
  end

  test "keeps a dependency-paused agent parked while its recorded blocker remains active" do
    parent = self()
    agent = spawn_link(fn -> control_agent(parent) end)
    assert_receive {:agent_started, ^agent}

    blocker = %{id: "blocker", identifier: "its-everdred/aiur#blocker", state: "in-progress"}
    previous = %{issue("blockee", "in-progress") | blocked_by: [blocker]}
    current = %{previous | blocked_by: [%{blocker | state: "rework"}]}

    entry = %{
      pid: agent,
      identifier: previous.identifier,
      issue: previous,
      control: %{status: :paused, can_interrupt: true},
      paused_reason: :blocker_dependency,
      blocker_pause_generation: 1,
      blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
    }

    unchanged =
      IssueSync.sync_polled_issue_state(
        %State{last_polled_issues: %{previous.id => previous}, running: %{previous.id => entry}, max_concurrent_agents: 2},
        [current],
        fn identifiers ->
          assert identifiers == [blocker.id]
          {:ok, [%{blocker | identifier: blocker.id, state: "rework"}]}
        end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    refute_receive {:resume_agent, _}, 100
    assert get_in(unchanged.running, [previous.id, :control, :status]) == :paused
    assert unchanged.running[previous.id].paused_reason == :blocker_dependency
  end

  test "resumes a dependency-paused agent when its recorded blocker is removed" do
    Publisher.set_tracked_fn(fn _ -> true end)

    blockee_identifier = "its-everdred/aiur#blockee"
    pause_topic = "ticket.#{blockee_identifier}.agent.attention.paused-blocker_dependency"
    cleared_topic = "ticket.#{blockee_identifier}.agent.dependency_cleared"
    :ok = Exchange.subscribe(pause_topic)
    :ok = Exchange.subscribe(cleared_topic)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    parent = self()
    agent = spawn_link(fn -> control_agent(parent) end)
    assert_receive {:agent_started, ^agent}

    blocker = %{id: "blocker", identifier: "its-everdred/aiur#blocker", state: "in-progress"}
    previous = %{issue("blockee", "in-progress") | blocked_by: [blocker]}
    current = %{previous | blocked_by: []}
    :ok = SubscriptionStore.attach(blockee_identifier)
    :ok = SubscriptionStore.attach(blocker.identifier)

    on_exit(fn ->
      SubscriptionStore.stop(blockee_identifier)
      SubscriptionStore.stop(blocker.identifier)
    end)

    entry = %{
      pid: agent,
      identifier: blockee_identifier,
      issue: previous,
      control: %{status: :paused, can_interrupt: true},
      paused_reason: :blocker_dependency,
      blocker_pause_generation: 1,
      blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
    }

    resumed =
      IssueSync.sync_polled_issue_state(
        %State{last_polled_issues: %{previous.id => previous}, running: %{previous.id => entry}, max_concurrent_agents: 2},
        [current],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_receive {:resume_agent, _request_id}
    assert_receive {:event, %{"reason" => reason, topic: ^cleared_topic}}, 2_000
    assert reason =~ "Dependency on blocker its-everdred/aiur#blocker was removed"
    assert get_in(resumed.running, [previous.id, :control, :status]) == :working
    refute_receive {:event, %{topic: ^pause_topic}}, 200
  end

  test "keeps a dependency-paused agent parked while another blocker remains active" do
    parent = self()
    agent = spawn_link(fn -> control_agent(parent) end)
    assert_receive {:agent_started, ^agent}

    blocker = %{id: "blocker", identifier: "its-everdred/aiur#blocker", state: "in-progress"}
    other_blocker = %{id: "other-blocker", identifier: "its-everdred/aiur#other-blocker", state: "rework"}
    previous = %{issue("blockee", "in-progress") | blocked_by: [blocker, other_blocker]}
    current = %{previous | blocked_by: [%{blocker | state: "done"}, other_blocker]}

    entry = %{
      pid: agent,
      identifier: previous.identifier,
      issue: previous,
      control: %{status: :paused, can_interrupt: true},
      paused_reason: :blocker_dependency,
      blocker_pause_generation: 1,
      blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
    }

    unchanged =
      IssueSync.sync_polled_issue_state(
        %State{last_polled_issues: %{previous.id => previous}, running: %{previous.id => entry}, max_concurrent_agents: 2},
        [current],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    refute_receive {:resume_agent, _}, 100
    assert get_in(unchanged.running, [previous.id, :control, :status]) == :paused
  end

  test "rechecks a dependency pause when its blocker is absent from the active poll" do
    parent = self()
    agent = spawn_link(fn -> control_agent(parent) end)
    assert_receive {:agent_started, ^agent}

    blockee = issue("blockee", "in-progress")
    blocker = issue("blocker", "done")

    entry = %{
      pid: agent,
      identifier: blockee.identifier,
      issue: blockee,
      control: %{status: :paused, can_interrupt: true},
      paused_reason: :blocker_dependency,
      blocker_pause_generation: 1,
      blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
    }

    resumed =
      IssueSync.sync_polled_issue_state(
        %State{last_polled_issues: %{blockee.id => blockee}, running: %{blockee.id => entry}, max_concurrent_agents: 2},
        [blockee],
        fn identifiers ->
          assert identifiers == [blocker.id]
          {:ok, [%{blocker | identifier: blocker.id}]}
        end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_receive {:resume_agent, _request_id}
    assert get_in(resumed.running, [blockee.id, :control, :status]) == :working

    {_queue_store, event} = AgentQueueStore.claim_next_deliverable(resumed.queue_store, blockee.identifier)
    assert event.event_type == :blocker_became_terminal
    assert event.body.blocker_issue_identifier == blocker.id
  end

  test "keeps a cleared blocker event off every agent that was not parked on that blocker" do
    parent = self()
    agent = spawn_link(fn -> control_agent(parent) end)
    assert_receive {:agent_started, ^agent}

    blockee = issue("blockee", "in-progress")
    blocker = issue("blocker", "done")
    unrelated = issue("unrelated", "in-progress")

    entry = %{
      pid: agent,
      identifier: blockee.identifier,
      issue: blockee,
      control: %{status: :paused, can_interrupt: true},
      paused_reason: :blocker_dependency,
      blocker_pause_generation: 1,
      blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
    }

    # Never blocked by anything, and working right now.
    unrelated_entry = %{
      identifier: unrelated.identifier,
      issue: unrelated,
      control: %{status: :working}
    }

    resumed =
      IssueSync.sync_polled_issue_state(
        %State{
          last_polled_issues: %{blockee.id => blockee, unrelated.id => unrelated},
          running: %{blockee.id => entry, unrelated.id => unrelated_entry},
          max_concurrent_agents: 4
        },
        [blockee, unrelated],
        fn identifiers ->
          assert identifiers == [blocker.id]
          {:ok, [%{blocker | identifier: blocker.id}]}
        end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    {queue_store, event} = AgentQueueStore.claim_next_deliverable(resumed.queue_store, blockee.identifier)
    assert event.event_type == :blocker_became_terminal

    assert {_queue_store, nil} = AgentQueueStore.claim_next_deliverable(queue_store, unrelated.identifier)
  end

  test "does not resume on a stale blocker set when the blockee is absent from the active poll" do
    parent = self()
    agent = spawn_link(fn -> control_agent(parent) end)
    assert_receive {:agent_started, ^agent}

    blocker = %{id: "blocker", identifier: "its-everdred/aiur#blocker", state: "done"}
    other_blocker = %{id: "other-blocker", identifier: "its-everdred/aiur#other-blocker", state: "in-progress"}

    # The snapshot the agent started with knows only the blocker that cleared.
    stored_blockee = %{issue("blockee", "in-progress") | blocked_by: [%{blocker | state: "in-progress"}]}
    # The tracker has since gained a second, still-open blocker.
    fresh_blockee = %{stored_blockee | blocked_by: [blocker, other_blocker]}

    entry = %{
      pid: agent,
      identifier: stored_blockee.identifier,
      issue: stored_blockee,
      control: %{status: :paused, can_interrupt: true},
      paused_reason: :blocker_dependency,
      blocker_pause_generation: 1,
      blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
    }

    unchanged =
      IssueSync.sync_polled_issue_state(
        %State{
          last_polled_issues: %{stored_blockee.id => stored_blockee},
          running: %{stored_blockee.id => entry},
          max_concurrent_agents: 2
        },
        [],
        fn
          ["blocker"] -> {:ok, [%{blocker | identifier: blocker.id}]}
          ["blockee"] -> {:ok, [fresh_blockee]}
        end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    refute_receive {:resume_agent, _}, 100
    assert get_in(unchanged.running, [stored_blockee.id, :control, :status]) == :paused
    assert unchanged.running[stored_blockee.id].paused_reason == :blocker_dependency

    assert {_queue_store, nil} =
             AgentQueueStore.claim_next_deliverable(unchanged.queue_store, stored_blockee.identifier)
  end

  test "reports waiting for capacity, not a blocker pause, when a cleared dependency resume is deferred" do
    Publisher.set_tracked_fn(fn _ -> true end)

    blockee_identifier = "its-everdred/aiur#blockee"
    pause_topic = "ticket.#{blockee_identifier}.agent.attention.paused-blocker_dependency"
    deferred_topic = "ticket.#{blockee_identifier}.agent.auto_resume_deferred"
    :ok = Exchange.subscribe(pause_topic)
    :ok = Exchange.subscribe(deferred_topic)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    parent = self()
    agent = spawn_link(fn -> control_agent(parent) end)
    assert_receive {:agent_started, ^agent}

    blocker = %{id: "blocker", identifier: "its-everdred/aiur#blocker", state: "in-progress"}
    previous = %{issue("blockee", "in-progress") | blocked_by: [blocker]}
    current = %{previous | blocked_by: [%{blocker | state: "done"}]}

    blockee = %{
      pid: agent,
      identifier: previous.identifier,
      issue: previous,
      control: %{status: :paused, can_interrupt: true},
      paused_reason: :blocker_dependency,
      blocker_pause_generation: 1,
      blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
    }

    busy = %{issue: issue("busy", "in-progress"), control: %{status: :working}}

    deferred =
      IssueSync.sync_polled_issue_state(
        %State{
          last_polled_issues: %{previous.id => previous},
          running: %{previous.id => blockee, "busy" => busy},
          max_concurrent_agents: 1
        },
        [current],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    refute_receive {:resume_agent, _}, 100
    assert deferred.running[previous.id].pending_auto_resume.resume_kind == :cleared_dependency

    assert_receive {:event, %{topic: ^deferred_topic} = alert}, 2_000
    assert alert["reason"] =~ "waiting for a dispatch slot"
    assert alert["needs_attention"] in [false, nil]

    refute_receive {:event, %{topic: ^pause_topic}}, 200
  end

  test "retries a cleared dependency resume when a later slot becomes available" do
    parent = self()
    agent = spawn_link(fn -> control_agent(parent) end)
    assert_receive {:agent_started, ^agent}

    blocker = %{id: "blocker", identifier: "its-everdred/aiur#blocker", state: "in-progress"}
    previous = %{issue("blockee", "in-progress") | blocked_by: [blocker]}
    current = %{previous | blocked_by: [%{blocker | state: "done"}]}

    blockee = %{
      pid: agent,
      identifier: previous.identifier,
      issue: previous,
      control: %{status: :paused, can_interrupt: true},
      paused_reason: :blocker_dependency,
      blocker_pause_generation: 1,
      blocker_pause: %{blocker_identifier: blocker.identifier, generation: 1}
    }

    busy = %{issue: issue("busy", "in-progress"), control: %{status: :working}}

    deferred =
      IssueSync.sync_polled_issue_state(
        %State{
          last_polled_issues: %{previous.id => previous},
          running: %{previous.id => blockee, "busy" => busy},
          max_concurrent_agents: 1
        },
        [current],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    refute_receive {:resume_agent, _}, 100
    assert deferred.running[previous.id].pending_auto_resume.resume_kind == :cleared_dependency

    resumed =
      %{deferred | running: %{previous.id => deferred.running[previous.id]}}
      |> PushRouting.reconcile_pending_auto_resumes()

    assert_receive {:resume_agent, _request_id}
    assert get_in(resumed.running, [previous.id, :control, :status]) == :working
    refute Map.has_key?(resumed.running[previous.id], :pending_auto_resume)
  end

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

    assert_receive {:event, %{topic: "system.dispatch.capacity_starved"} = event}, 500
    assert event["reason"] =~ "Ready tickets=1"
    assert event["reason"] =~ "effective cap=4, configured cap=4"
    assert event["reason"] =~ "load-envelope limit"
    assert event["reason"] =~ "memory gate"
    assert event["reason"] =~ "FD gate"
    assert event["reason"] =~ "load gate"
    assert event["reason"] =~ "prewarm build"
    refute event["reason"] =~ "cold-start"

    assert IssueSync.sync_capacity_starvation_alert(alerted, [ready], 122_000) == alerted
    refute_receive {:event, %{topic: "system.dispatch.capacity_starved"}}, 100

    recovered = IssueSync.sync_capacity_starvation_alert(alerted, [], 122_000)
    assert recovered.capacity_starvation == %{since_ms: %{}, alert_active: false, signature: [], alerted: []}
    assert_receive {:event, %{topic: "system.dispatch.capacity_starved.resolved"}}, 500

    rearmed = IssueSync.sync_capacity_starvation_alert(recovered, [ready], 200_000)
    _ = IssueSync.sync_capacity_starvation_alert(rearmed, [ready], 260_000)
    assert_receive {:event, %{topic: "system.dispatch.capacity_starved"}}, 500
  end

  test "emits a debounced fleet starvation alert for ready work below unused capacity" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.fleet.capacity.starved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    ready = for id <- 1..8, do: issue("ready-#{id}", "todo")

    state = %State{
      max_concurrent_agents: 20,
      effective_concurrent_agents: 20,
      running: running_agents(3),
      dispatch_capacity_sample: %{load: 0.7, target: 1.0, schedulers: 16}
    }

    waiting = IssueSync.sync_fleet_capacity_starved_alert(state, ready, 1_000)
    refute waiting.fleet_capacity_starvation.alert_active
    refute_receive {:event, %{topic: "system.fleet.capacity.starved"}}, 100

    alerted = IssueSync.sync_fleet_capacity_starved_alert(waiting, ready, 61_000)
    assert alerted.fleet_capacity_starvation.alert_active

    assert_receive {:event, %{topic: "system.fleet.capacity.starved"} = event}, 500
    assert event["needs_attention"] == true
    assert event["reason"] =~ "Ready tickets=8, live agents=3"
    assert event["reason"] =~ "load=0.7/16.0"
    assert event["reason"] =~ "effective cap=20, configured cap=20"
    assert event["reason"] =~ "binding constraint=no binding constraint identified"
  end

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
    refute_receive {:event, %{topic: ^topic}}, 100

    alerted = IssueSync.sync_dependency_circular_wait_alert(waiting, [keystone], 61_000)
    assert alerted.dependency_circular_wait[keystone.id].alerted?

    assert_receive {:event, %{topic: ^topic} = event}, 500
    assert event["needs_attention"] == true
    assert event["reason"] =~ keystone.identifier
    assert event["reason"] =~ "2 parked agent(s)"

    repeated = IssueSync.sync_dependency_circular_wait_alert(alerted, [keystone], 122_000)
    assert repeated == alerted
    refute_receive {:event, %{topic: ^topic}}, 100

    held = %{repeated | capacity_hold: %{signal: :load}}
    assert IssueSync.sync_dependency_circular_wait_alert(held, [keystone], 123_000) == held
    refute_receive {:event, %{topic: ^resolved_topic}}, 100

    resumed = %{held | capacity_hold: nil}
    assert IssueSync.sync_dependency_circular_wait_alert(resumed, [keystone], 124_000).dependency_circular_wait == repeated.dependency_circular_wait
    refute_receive {:event, %{topic: ^topic}}, 100

    dispatched = %{
      resumed
      | running:
          resumed.running
          |> Map.delete("operator-pause")
          |> Map.put(keystone.id, %{control: %{status: :working}, issue: keystone})
    }

    recovered = IssueSync.sync_dependency_circular_wait_alert(dispatched, [keystone], 123_000)
    assert recovered.dependency_circular_wait == %{}
    assert_receive {:event, %{topic: ^resolved_topic}}, 500
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

    refute_receive {:event, %{topic: ^topic}}, 100
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

    refute_receive {:event, %{topic: "system.fleet.capacity.starved"}}, 100
  end

  test "reports a static load envelope as the binding constraint" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.fleet.capacity.starved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    ready = for id <- 1..8, do: issue("envelope-#{id}", "todo")

    state = %State{
      max_concurrent_agents: 20,
      effective_concurrent_agents: 3,
      running: running_agents(3),
      dispatch_capacity_sample: %{load: 0.7, target: 1.0, schedulers: 16}
    }

    state
    |> IssueSync.sync_fleet_capacity_starved_alert(ready, 1_000)
    |> IssueSync.sync_fleet_capacity_starved_alert(ready, 61_000)

    assert_receive {:event, %{topic: "system.fleet.capacity.starved"} = event}, 500
    assert event["reason"] =~ "binding constraint=load envelope (effective cap=3)"
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

    assert_receive {:event, %{topic: "system.fleet.capacity.starved"} = event}, 500
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

    assert_receive {:event, %{topic: "system.fleet.capacity.starved"} = event}, 500
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

    assert_receive {:event, %{topic: "system.fleet.capacity.starved"} = event}, 500
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

    assert_receive {:event, %{topic: "system.fleet.capacity.starved"} = event}, 500

    assert event["reason"] =~
             "binding constraint=dispatch authorization denials (all fallback backends usage-limited for 8 ready ticket(s))"
  end

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

    assert_receive {:event, %{topic: "system.fleet.capacity.starved"}}, 500

    recovered = IssueSync.sync_fleet_capacity_starved_alert(alerted, [], 62_000)
    assert recovered.fleet_capacity_starvation == %{since_ms: nil, alert_active: false, effective_cap: nil}
    assert_receive {:event, %{topic: "system.fleet.capacity.starved.resolved"}}, 500

    rearmed = IssueSync.sync_fleet_capacity_starved_alert(recovered, ready, 100_000)
    _ = IssueSync.sync_fleet_capacity_starved_alert(rearmed, ready, 160_000)
    assert_receive {:event, %{topic: "system.fleet.capacity.starved"}}, 500
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
    refute_receive {:event, %{topic: "system.fleet.capacity.starved"}}, 100
  end

  test "purges released claims once the ticket is confirmed terminal or gone (#1475)" do
    active = issue("released-active", "in-progress")
    closed = issue("released-closed", "done")
    vanished = issue("released-vanished", "todo")

    release = %{cause: :rate_limit, details: %{}, released_at_ms: 1}

    state = %State{
      last_polled_issues: %{active.id => active, closed.id => closed, vanished.id => vanished},
      released_claims: %{active.id => release, closed.id => release, vanished.id => release}
    }

    synced =
      IssueSync.sync_polled_issue_state(
        state,
        [active, closed],
        # Verification resolves the absent ticket: it is genuinely closed.
        fn _ -> {:ok, [issue("released-vanished", "done")]} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    # The claim an operator can still recover survives the poll.
    assert %{cause: :rate_limit} = synced.released_claims[active.id]

    # A closed ticket and a ticket confirmed gone are both unrecoverable, so
    # their entries must not keep inflating RELEASED CLAIMS.
    refute Map.has_key?(synced.released_claims, closed.id)
    refute Map.has_key?(synced.released_claims, vanished.id)
  end

  test "keeps a released claim when the ticket's absence is not yet confirmed (#1475)" do
    active = issue("released-active", "in-progress")
    absent = issue("released-absent", "todo")

    release = %{cause: :rate_limit, details: %{}, released_at_ms: 1}

    state = %State{
      last_polled_issues: %{active.id => active, absent.id => absent},
      released_claims: %{absent.id => release}
    }

    synced =
      IssueSync.sync_polled_issue_state(
        state,
        [active],
        # A claim is released because the tracker was failing, which is exactly
        # when a poll comes back partial. Verification cannot confirm the
        # absence here, so the ticket stays pending — and so must its claim.
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert %{cause: :rate_limit} = synced.released_claims[absent.id]
  end

  test "alerts when the tracker adds or removes agent:paused" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("ticket.its-everdred/aiur#pause-transition.agent.paused")
    :ok = Exchange.subscribe("ticket.its-everdred/aiur#pause-transition.agent.unpaused")
    :ok = Exchange.subscribe("ticket.its-everdred/aiur#pause-transition.agent.paused.resolved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    previous = issue("pause-transition", "in-progress")
    paused = %{previous | paused: true}

    state =
      IssueSync.sync_polled_issue_state(
        %State{last_polled_issues: %{previous.id => previous}},
        [paused],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert state.last_polled_issues == %{paused.id => paused}

    assert_receive {:event, %{topic: "ticket.its-everdred/aiur#pause-transition.agent.paused"} = event}, 500

    assert event["reason"] =~ "tracker pause override"
    assert event["reason"] =~ "clears when the operator removes agent:paused"
    assert event["needs_attention"] == true

    _ =
      IssueSync.sync_polled_issue_state(
        state,
        [previous],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_receive {:event, %{topic: "ticket.its-everdred/aiur#pause-transition.agent.unpaused"} = event}, 500

    assert event["reason"] =~ "No operator action is needed"
    assert event["needs_attention"] == false
    assert_receive {:event, %{topic: "ticket.its-everdred/aiur#pause-transition.agent.paused.resolved"}}, 500
  end

  test "persists a reason-carrying fallback when polling observes an ordinary error transition" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("ticket.its-everdred/aiur#observed-error.agent.attention.error-observed_tracker_error")
    :ok = Exchange.subscribe("ticket.its-everdred/aiur#observed-error.agent.attention.error-observed_tracker_error.resolved")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    previous = issue("observed-error", "rework")
    errored = %{previous | state: "error"}

    state =
      IssueSync.sync_polled_issue_state(
        %State{last_polled_issues: %{previous.id => previous}},
        [errored],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert MapSet.member?(state.observed_error_alerts, previous.id)

    assert_receive {:event, %{topic: "ticket.its-everdred/aiur#observed-error.agent.attention.error-observed_tracker_error"} = event}, 500
    assert event["reason"] =~ "without a specialized local cause"
    assert event["reason"] =~ "will not clear on its own"
    assert event["needs_attention"] == true

    recovered = %{errored | state: "rework"}

    recovered_state =
      IssueSync.sync_polled_issue_state(
        state,
        [recovered],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    refute MapSet.member?(recovered_state.observed_error_alerts, previous.id)
    assert_receive {:event, %{topic: "ticket.its-everdred/aiur#observed-error.agent.attention.error-observed_tracker_error.resolved"}}, 500

    _ =
      IssueSync.sync_polled_issue_state(
        recovered_state,
        [errored],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_receive {:event, %{topic: "ticket.its-everdred/aiur#observed-error.agent.attention.error-observed_tracker_error"}}, 500
  end

  test "does not resolve an observed error while its lifetime latch remains active" do
    Publisher.set_tracked_fn(fn _ -> true end)
    issue = issue("latched-error", "rework")
    topic = "ticket.#{issue.identifier}.agent.attention.error-lifetime_latch"
    resolved_topic = "#{topic}.resolved"
    :ok = Exchange.subscribe(resolved_topic)
    write_central_attention!(topic)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    state = %State{
      observed_error_alerts: MapSet.new([issue.id]),
      observed_error_alert_causes: %{issue.id => :lifetime_latch},
      dispatch_recovery: %{codex_thrash_budget: %{issue.id => %{tripped: :lifetime, lifetime: 2}}}
    }

    recovered =
      IssueSync.sync_polled_issue_state(
        state,
        [issue],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert MapSet.member?(recovered.observed_error_alerts, issue.id)
    assert recovered.observed_error_alert_causes[issue.id] == :lifetime_latch
    refute_receive {:event, %{topic: ^resolved_topic}}, 100
  end

  test "re-evaluates a latched error after recovery while tracker state stays unchanged" do
    Publisher.set_tracked_fn(fn _ -> true end)
    issue = issue("latched-error-recovered", "rework")
    topic = "ticket.#{issue.identifier}.agent.attention.error-lifetime_latch"
    resolved_topic = "#{topic}.resolved"
    :ok = Exchange.subscribe(resolved_topic)
    write_central_attention!(topic)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    recovered =
      IssueSync.sync_polled_issue_state(
        %State{
          last_polled_issues: %{issue.id => issue},
          observed_error_alerts: MapSet.new([issue.id]),
          observed_error_alert_causes: %{issue.id => :lifetime_latch}
        },
        [issue],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    refute MapSet.member?(recovered.observed_error_alerts, issue.id)
    refute Map.has_key?(recovered.observed_error_alert_causes, issue.id)
    assert_receive {:event, %{topic: ^resolved_topic}}, 500
  end

  test "rediscovers and resolves a persisted lifetime latch attention after restart" do
    Publisher.set_tracked_fn(fn _ -> true end)
    issue = issue("latched-error-restart", "rework")
    topic = "ticket.#{issue.identifier}.agent.attention.error-lifetime_latch"
    resolved_topic = "#{topic}.resolved"
    :ok = Exchange.subscribe(resolved_topic)
    write_central_attention!(topic)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    recovered =
      IssueSync.sync_polled_issue_state(
        %State{},
        [issue],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    refute MapSet.member?(recovered.observed_error_alerts, issue.id)
    assert_receive {:event, %{topic: ^resolved_topic}}, 500
  end

  test "retains a persisted lifetime latch attention when its budget store is unreadable" do
    Publisher.set_tracked_fn(fn _ -> true end)
    write_workflow_file!(Workflow.workflow_file_path(), max_dispatches_per_ticket: 10)
    issue = issue("latched-error-store-failure", "rework")
    topic = "ticket.#{issue.identifier}.agent.attention.error-lifetime_latch"
    resolved_topic = "#{topic}.resolved"
    store_path = Path.join(System.tmp_dir!(), "dispatch-budget-invalid-#{System.unique_integer([:positive])}.json")
    previous_store_path = Application.get_env(:aiur, :dispatch_budget_store_path)
    Application.put_env(:aiur, :dispatch_budget_store_path, store_path)
    File.write!(store_path, "not json")
    :ok = Exchange.subscribe(resolved_topic)
    write_central_attention!(topic)

    on_exit(fn ->
      if is_nil(previous_store_path),
        do: Application.delete_env(:aiur, :dispatch_budget_store_path),
        else: Application.put_env(:aiur, :dispatch_budget_store_path, previous_store_path)

      File.rm(store_path)
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    recovered =
      IssueSync.sync_polled_issue_state(
        %State{},
        [issue],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert MapSet.member?(recovered.observed_error_alerts, issue.id)
    assert recovered.observed_error_alert_causes[issue.id] == :lifetime_latch
    refute_receive {:event, %{topic: ^resolved_topic}}, 100
  end

  test "resolves and rearms a persisted observed error after restart" do
    Publisher.set_tracked_fn(fn _ -> true end)
    issue = issue("observed-error-restart", "rework")
    topic = "ticket.#{issue.identifier}.agent.attention.error-observed_tracker_error"
    resolved_topic = "#{topic}.resolved"
    :ok = Exchange.subscribe(topic)
    :ok = Exchange.subscribe(resolved_topic)
    write_central_attention!(topic)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    recovered =
      IssueSync.sync_polled_issue_state(
        %State{},
        [issue],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_receive {:event, %{topic: ^resolved_topic}}, 500
    assert AlertFeed.list(ledger_paths: [AlertLedger.path()], needs_attention: true) == []

    _ =
      IssueSync.sync_polled_issue_state(
        recovered,
        [%{issue | state: "error"}],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_receive {:event, %{topic: ^topic}}, 500
  end

  test "resolves a persisted retry-exhaustion error with its own cause after restart" do
    Publisher.set_tracked_fn(fn _ -> true end)
    issue = issue("retry-error-restart", "rework")
    topic = "ticket.#{issue.identifier}.agent.attention.error-retry_exhausted"
    resolved_topic = "#{topic}.resolved"
    :ok = Exchange.subscribe(resolved_topic)
    write_central_attention!(topic)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    _ =
      IssueSync.sync_polled_issue_state(
        %State{},
        [issue],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_receive {:event, %{topic: ^resolved_topic}}, 500
  end

  test "resolves and rearms a persisted tracker pause after restart" do
    Publisher.set_tracked_fn(fn _ -> true end)
    issue = issue("pause-restart", "rework")
    paused = %{issue | paused: true}
    topic = "ticket.#{issue.identifier}.agent.paused"
    resolved_topic = "#{topic}.resolved"
    workspace = Aiur.Workspace.workspace_path_under(Config.workspace_root(), issue.identifier)
    File.mkdir_p!(workspace)
    :ok = Exchange.subscribe(topic)
    :ok = Exchange.subscribe(resolved_topic)

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    _opened =
      IssueSync.sync_polled_issue_state(
        %State{},
        [paused],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_receive {:event, %{topic: ^topic}}, 500

    assert Enum.any?(AlertFeed.list(ledger_paths: [AlertLedger.path()]), &(&1["topic"] == topic))

    _restart_with_pause =
      IssueSync.sync_polled_issue_state(
        %State{},
        [paused],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    refute_receive {:event, %{topic: ^topic}}, 100

    recovered =
      IssueSync.sync_polled_issue_state(
        %State{},
        [issue],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_receive {:event, %{topic: ^resolved_topic}}, 500
    assert AlertFeed.list(ledger_paths: [AlertLedger.path()], needs_attention: true) == []

    _ =
      IssueSync.sync_polled_issue_state(
        recovered,
        [paused],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_receive {:event, %{topic: ^topic}}, 500
  end

  test "does not duplicate an error alert already emitted by a specialized producer" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("ticket.its-everdred/aiur#specialized-error.agent.attention.error-observed_tracker_error")

    on_exit(fn ->
      Publisher.set_tracked_fn(fn _ -> true end)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    previous = issue("specialized-error", "rework")
    errored = %{previous | state: "error"}

    _ =
      IssueSync.sync_polled_issue_state(
        %State{last_polled_issues: %{previous.id => previous}, observed_error_alerts: MapSet.new([previous.id])},
        [errored],
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    refute_receive {:event, %{topic: "ticket.its-everdred/aiur#specialized-error.agent.attention.error-observed_tracker_error"}}, 100
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
    refute_receive {:event, %{topic: "system.dispatch.capacity_starved"}}, 100

    alerted = IssueSync.sync_capacity_starvation_alert(reset, [ready], 121_000)
    assert alerted.capacity_starvation.alert_active
    assert_receive {:event, %{topic: "system.dispatch.capacity_starved"} = event}, 500
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
    assert_receive {:event, %{topic: "system.dispatch.capacity_starved"} = event}, 500
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
    assert_receive {:event, %{topic: "system.dispatch.capacity_starved"} = event}, 500
    assert event["reason"] =~ "budget latch (lifetime=20)"
  end

  test "records an idle completed ticket before an active-only poll drops it" do
    previous_issue = issue("42", "in-progress")

    state = %State{last_polled_issues: %{"42" => previous_issue}}
    parent = self()

    refreshed_state =
      IssueSync.sync_polled_issue_state(
        state,
        [],
        fn ["42"] -> {:ok, [%{previous_issue | state: "done"}]} end,
        fn identity, lifecycle ->
          send(parent, {:membership_observed, identity, lifecycle})
          :ok
        end,
        MapSet.new(["done", "cancelled"]),
        fn _status -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_receive {:membership_observed, %TrackerIdentity{provider_id: "node-42"}, :completed}
    assert refreshed_state.last_polled_issues == %{}
  end

  test "records an idle cancelled ticket before an active-only poll drops it" do
    previous_issue = issue("43", "in-progress")

    state = %State{last_polled_issues: %{"43" => previous_issue}}
    parent = self()

    refreshed_state =
      IssueSync.sync_polled_issue_state(
        state,
        [],
        fn ["43"] -> {:ok, [%{previous_issue | state: "cancelled"}]} end,
        fn identity, lifecycle ->
          send(parent, {:membership_observed, identity, lifecycle})
          :ok
        end,
        MapSet.new(["done", "cancelled"]),
        fn _status -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_receive {:membership_observed, %TrackerIdentity{provider_id: "node-43"}, :cancelled}
    assert refreshed_state.last_polled_issues == %{}
  end

  test "does not infer a terminal transition from an idle ticket's absence" do
    previous_issue = issue("44", "in-progress")
    state = %State{last_polled_issues: %{"44" => previous_issue}}
    parent = self()

    refreshed_state =
      IssueSync.sync_polled_issue_state(
        state,
        [],
        fn ["44"] -> {:ok, []} end,
        fn identity, lifecycle ->
          send(parent, {:membership_observed, identity, lifecycle})
          :ok
        end,
        MapSet.new(["done", "cancelled"]),
        fn _status -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    refute_receive {:membership_observed, _, _}
    assert refreshed_state.last_polled_issues == %{"44" => previous_issue}
  end

  test "retries an idle terminal verification after a transient by-id failure" do
    previous_issue = issue("45", "in-progress")
    state = %State{last_polled_issues: %{"45" => previous_issue}}
    parent = self()

    unavailable =
      IssueSync.sync_polled_issue_state(
        state,
        [],
        fn ["45"] -> {:error, :temporarily_unavailable} end,
        fn _identity, _lifecycle -> flunk("must not record membership before verification") end,
        MapSet.new(["done", "cancelled"]),
        fn :unavailable -> send(parent, :membership_freshness_unavailable) end,
        fn _identity, _pending? -> :ok end
      )

    assert_receive :membership_freshness_unavailable
    assert unavailable.last_polled_issues == %{"45" => previous_issue}

    recovered =
      IssueSync.sync_polled_issue_state(
        unavailable,
        [],
        fn ["45"] -> {:ok, [%{previous_issue | state: "done"}]} end,
        fn identity, lifecycle ->
          send(parent, {:membership_observed, identity, lifecycle})
          :ok
        end,
        MapSet.new(["done", "cancelled"]),
        fn _status -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_receive {:membership_observed, %TrackerIdentity{provider_id: "node-45"}, :completed}
    assert recovered.last_polled_issues == %{}
  end

  test "retains a terminal ticket when membership persistence rejects its observation" do
    previous_issue = issue("46", "in-progress")
    state = %State{last_polled_issues: %{"46" => previous_issue}}
    parent = self()

    pending =
      IssueSync.sync_polled_issue_state(
        state,
        [],
        fn ["46"] -> {:ok, [%{previous_issue | state: "done"}]} end,
        fn _identity, _lifecycle -> {:error, :disk_full} end,
        MapSet.new(["done", "cancelled"]),
        fn status -> send(parent, {:freshness, status}) end,
        fn _identity, pending? ->
          send(parent, {:terminal_verification_pending, pending?})
          :ok
        end
      )

    assert_receive {:freshness, :unavailable}
    assert pending.last_polled_issues == %{"46" => previous_issue}

    resolved =
      IssueSync.sync_polled_issue_state(
        pending,
        [],
        fn ["46"] -> {:ok, [%{previous_issue | state: "done"}]} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done", "cancelled"]),
        fn _status -> :ok end,
        fn _identity, pending? ->
          send(parent, {:terminal_verification_pending, pending?})
          :ok
        end
      )

    assert resolved.last_polled_issues == %{}
  end

  test "isolates an unavailable projection marker while retaining terminal verification" do
    previous_issue = issue("47", "in-progress")
    state = %State{last_polled_issues: %{"47" => previous_issue}}
    parent = self()

    result =
      IssueSync.sync_polled_issue_state(
        state,
        [],
        fn ["47"] -> {:error, :temporarily_unavailable} end,
        fn _identity, _lifecycle -> flunk("must not observe without a tracker result") end,
        MapSet.new(["done", "cancelled"]),
        fn :unavailable -> exit(:noproc) end,
        fn _identity, pending? -> send(parent, {:terminal_verification_pending, pending?}) end
      )

    assert result.last_polled_issues == %{"47" => previous_issue}
  end

  test "chunks disappearing idle verification across polls" do
    previous_issues =
      for id <- 1..250, into: %{}, do: {Integer.to_string(id), issue(Integer.to_string(id), "in-progress")}

    parent = self()
    state = %State{last_polled_issues: previous_issues}

    result =
      IssueSync.sync_polled_issue_state(
        state,
        [],
        fn ids ->
          send(parent, {:verified_ids, ids})
          {:ok, []}
        end,
        fn _identity, _lifecycle -> flunk("absent tickets cannot be inferred terminal") end,
        MapSet.new(["done", "cancelled"]),
        fn _status -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    assert_receive {:verified_ids, ids}
    assert length(ids) == 25
    assert map_size(result.last_polled_issues) == 250
  end

  defp issue(id, state) do
    %Issue{
      id: id,
      identifier: "its-everdred/aiur##{id}",
      title: "Issue #{id}",
      state: state,
      tracker_identity: %TrackerIdentity{
        version: 1,
        status: :joinable,
        kind: :github,
        owner: "its-everdred",
        repository: "aiur",
        provider_id: "node-#{id}",
        identifier: id,
        reason: nil
      }
    }
  end

  defp control_agent(parent) do
    send(parent, {:agent_started, self()})
    control_agent_loop(parent)
  end

  defp control_agent_loop(parent) do
    receive do
      message ->
        send(parent, message)
        control_agent_loop(parent)
    end
  end

  defp running_agents(count, issue_state \\ nil) do
    for id <- 1..count, into: %{} do
      entry = if issue_state, do: %{issue: issue("live-#{id}", issue_state)}, else: %{}
      {"live-#{id}", entry}
    end
  end

  defp dependency_paused_entry(blocker_identifier) do
    %{
      control: %{status: :paused},
      paused_reason: :blocker_dependency,
      blocker_pause: %{blocker_identifier: blocker_identifier}
    }
  end

  defp write_central_attention!(topic) do
    log_path = AlertLedger.path()
    File.mkdir_p!(Path.dirname(log_path))

    File.write!(
      log_path,
      ~s({"event":"alert","timestamp":"2026-08-02T01:00:00Z","topic":"#{topic}","message":"persisted attention","needs_attention":true}\n)
    )
  end
end
