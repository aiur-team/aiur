defmodule Aiur.Orchestrator.IssueSyncTest do
  use Aiur.TestSupport

  alias Aiur.{AlertFeed, AlertLedger, Config, Issue, TrackerIdentity, Workflow}
  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.Orchestrator.{IssueSync, State}

  test "ignores a non-list poll result" do
    state = %State{last_polled_issues: %{"42" => %{id: "42"}}}

    assert IssueSync.sync_polled_issue_state(state, :invalid) == state
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

  test "purges released claims once the ticket is terminal or gone from the poll (#1475)" do
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
        fn _ -> {:ok, []} end,
        fn _identity, _lifecycle -> :ok end,
        MapSet.new(["done"]),
        fn _ -> :ok end,
        fn _identity, _pending? -> :ok end
      )

    # The claim an operator can still recover survives the poll.
    assert %{cause: :rate_limit} = synced.released_claims[active.id]

    # A closed ticket and a ticket the tracker stopped returning are both
    # unrecoverable, so their entries must not keep inflating RELEASED CLAIMS.
    refute Map.has_key?(synced.released_claims, closed.id)
    refute Map.has_key?(synced.released_claims, vanished.id)
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
    write_workflow_file_synced!(Workflow.workflow_file_path(), max_dispatches_per_ticket: 10)
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

  defp running_agents(count, issue_state \\ nil) do
    for id <- 1..count, into: %{} do
      entry = if issue_state, do: %{issue: issue("live-#{id}", issue_state)}, else: %{}
      {"live-#{id}", entry}
    end
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
