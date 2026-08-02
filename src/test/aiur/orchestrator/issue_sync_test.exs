defmodule Aiur.Orchestrator.IssueSyncTest do
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.{Issue, TrackerIdentity, Workflow}
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
    assert event["reason"] =~ "build gate"
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
    :ok = Exchange.subscribe("ticket.its-everdred/aiur#observed-error.agent.attention.error")
    :ok = Exchange.subscribe("ticket.its-everdred/aiur#observed-error.agent.attention.error.resolved")

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

    assert_receive {:event, %{topic: "ticket.its-everdred/aiur#observed-error.agent.attention.error"} = event}, 500
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
    assert_receive {:event, %{topic: "ticket.its-everdred/aiur#observed-error.agent.attention.error.resolved"}}, 500

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

    assert_receive {:event, %{topic: "ticket.its-everdred/aiur#observed-error.agent.attention.error"}}, 500
  end

  test "does not duplicate an error alert already emitted by a specialized producer" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("ticket.its-everdred/aiur#specialized-error.agent.attention.error")

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

    refute_receive {:event, %{topic: "ticket.its-everdred/aiur#specialized-error.agent.attention.error"}}, 100
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
end
