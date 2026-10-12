defmodule Aiur.Orchestrator.Status.SnapshotProjectionTest do
  use Aiur.TestSupport

  import Aiur.OrchestratorStatusSupport

  alias Aiur.AgentQueueStore
  alias Aiur.Orchestrator.ControlLifecycle
  alias Aiur.Orchestrator.SnapshotStore
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReport

  test "dashboard projection excludes unrelated orchestration state" do
    {queue_store, _item} =
      AgentQueueStore.enqueue(
        AgentQueueStore.new(),
        Aiur.AgentQueue.operator_message("MT-UNRELATED", String.duplicate("q", 64_000))
      )

    state = %State{
      github_comment_issue_updated_at: Map.new(1..1_000, &{"issue-#{&1}", %{payload: String.duplicate("x", 64)}}),
      ci_lifecycle: %{
        %State{}.ci_lifecycle
        | poll_cache: Map.new(1..1_000, &{"MT-#{&1}", %{payload: String.duplicate("c", 64)}})
      },
      control_lifecycle: %Aiur.Orchestrator.ControlLifecycle{
        records: Map.new(1..1_000, &{"request-#{&1}", %{payload: String.duplicate("l", 64)}})
      },
      queue_store: queue_store
    }

    assert %{status_observed_at: %DateTime{}} = snapshot_input = StatusReport.snapshot_input(state)

    assert %{snapshot_input | status_observed_at: nil} == %State{}
  end

  test "dashboard projection retains queue facts for rendered issues" do
    {queue_store, _item} =
      AgentQueueStore.enqueue(
        AgentQueueStore.new(),
        Aiur.AgentQueue.operator_message("MT-QUEUED", "show this message")
      )

    state = %State{
      running: %{"issue-queued" => running_entry("issue-queued", "MT-QUEUED", :working)},
      queue_store: queue_store
    }

    snapshot = state |> StatusReport.snapshot_input() |> StatusReport.snapshot_payload()

    assert [%{queue_depth: 1, pending_operator_messages: [%{text: "show this message"}]}] = snapshot.running
  end

  test "dashboard projection retains the latest declined resume and held pause condition" do
    issue_id = "issue-declined-resume"

    entry =
      issue_id
      |> running_entry("MT-DECLINED-RESUME", :paused)
      |> Map.put(:paused_reason, :max_agent_duration)

    attrs = %{
      request_id: 91,
      issue_id: issue_id,
      tracker_identity: entry.issue.tracker_identity,
      action: :resume,
      generation: 1,
      expected_status: :paused,
      expected_version: 0,
      requester: :operator
    }

    lifecycle = ControlLifecycle.new(now: ~U[2026-08-11 12:00:00Z])
    {:ok, _request, lifecycle} = ControlLifecycle.request(lifecycle, attrs, now: ~U[2026-08-11 12:00:00Z])
    {:ok, _request, lifecycle} = ControlLifecycle.accept(lifecycle, 91, 1, now: ~U[2026-08-11 12:00:01Z])

    {:ok, _request, lifecycle} =
      ControlLifecycle.reject(lifecycle, 91, :not_eligible,
        now: ~U[2026-08-11 12:00:02Z],
        condition: %{control_status: :paused, pause_reason: :max_agent_duration}
      )

    {:ok, _request, lifecycle} =
      ControlLifecycle.request(
        lifecycle,
        %{attrs | request_id: 92, action: :pause, expected_status: :working},
        now: ~U[2026-08-11 12:00:03Z]
      )

    snapshot =
      %State{running: %{issue_id => entry}, control_lifecycle: lifecycle}
      |> StatusReport.snapshot_input()
      |> StatusReport.snapshot_payload()

    assert [row] = snapshot.running
    assert row.pause_reason == :max_agent_duration

    assert %{action: :pause, request_id: 92, status: :requested} = row.control.latest_control

    assert %{
             action: :resume,
             request_id: 91,
             status: :rejected,
             rejection: %{
               class: :not_eligible,
               condition: %{control_status: :paused, pause_reason: :max_agent_duration}
             }
           } = row.control.latest_resume_control

    assert Enum.map(row.control.recent_controls, & &1.request_id) == [91, 92]
  end

  test "dashboard projection retains a dropped resume and its expiry reason" do
    issue_id = "issue-dropped-resume"

    entry =
      issue_id
      |> running_entry("MT-DROPPED-RESUME", :paused)
      |> Map.put(:paused_reason, :operator_pause)

    attrs = %{
      request_id: 93,
      issue_id: issue_id,
      tracker_identity: entry.issue.tracker_identity,
      action: :resume,
      generation: 1,
      expected_status: :paused,
      expected_version: 0,
      requester: :operator
    }

    lifecycle = ControlLifecycle.new(now: ~U[2026-08-11 12:00:00Z])
    {:ok, _request, lifecycle} = ControlLifecycle.request(lifecycle, attrs, now: ~U[2026-08-11 12:00:00Z])
    {:ok, _request, lifecycle} = ControlLifecycle.accept(lifecycle, 93, 1, now: ~U[2026-08-11 12:00:01Z])
    {[expired], lifecycle} = ControlLifecycle.expire_due(lifecycle, 1_000, now: ~U[2026-08-11 12:00:02.001Z])
    assert expired.expiry.reason == :timeout

    snapshot =
      %State{running: %{issue_id => entry}, control_lifecycle: lifecycle}
      |> StatusReport.snapshot_input()
      |> StatusReport.snapshot_payload()

    assert [row] = snapshot.running
    assert row.pause_reason == :operator_pause

    assert %{action: :resume, request_id: 93, status: :expired, expiry: %{reason: :timeout}} =
             row.control.latest_resume_control
  end

  test "dashboard projection retains CI facts for retries absent from the latest poll" do
    state = %State{
      retry_attempts: %{
        "issue-retrying" => %{
          attempt: 2,
          due_at_ms: System.monotonic_time(:millisecond) + 1_000,
          identifier: "MT-RETRY-CI"
        }
      },
      ci_lifecycle: %{
        %State{}.ci_lifecycle
        | poll_cache: %{"MT-RETRY-CI" => %{decision: :pending, pr_number: 1501}}
      }
    }

    snapshot = state |> StatusReport.snapshot_input() |> StatusReport.snapshot_payload()

    assert [%{identifier: "MT-RETRY-CI", ci_result: %{decision: :pending, pr_number: 1501}}] = snapshot.retrying
  end

  test "capacity hold is projected with the measured limiting signal and threshold" do
    held_at = System.monotonic_time(:millisecond) - 5_000

    state = %State{
      capacity_hold: %{
        signal: :build,
        measured: %{active: 2, queued: 1},
        threshold: 2,
        held_since_ms: held_at,
        alerted?: true
      }
    }

    snapshot = state |> StatusReport.snapshot_input() |> StatusReport.snapshot_payload()

    assert %{
             held?: true,
             signal: :build,
             measured: %{active: 2, queued: 1},
             threshold: 2,
             held_for_seconds: 5
           } = snapshot.capacity_hold
  end

  test "provider capacity hold projects freshness details for status" do
    detail = "codex=stale observed_at=2026-10-06T10:00:00Z next_probe=unknown"

    snapshot =
      %State{
        capacity_hold: %{
          signal: :provider,
          measured: ["codex"],
          detail: detail,
          threshold: :all_usage_limited,
          held_since_ms: System.monotonic_time(:millisecond),
          alerted?: false
        }
      }
      |> StatusReport.snapshot_input()
      |> StatusReport.snapshot_payload()

    assert snapshot.capacity_hold.signal == :provider
    assert snapshot.capacity_hold.detail == detail
  end

  # How long the hold has lasted and how old its measurement is are independent:
  # a hold extended by a fresh probe keeps ageing while its figure does not. Only
  # the sample age says whether `measured` still describes the host (#2527).
  test "a capacity hold projects its sample age separately from how long it has held" do
    state = %State{
      capacity_hold: %{
        signal: :load,
        measured: 24.14,
        threshold: 24.0,
        held_since_ms: System.monotonic_time(:millisecond) - 600_000,
        measured_at: DateTime.add(DateTime.utc_now(), -30, :second),
        alerted?: true
      }
    }

    snapshot = state |> StatusReport.snapshot_input() |> StatusReport.snapshot_payload()

    assert snapshot.capacity_hold.held_for_seconds == 600
    assert snapshot.capacity_hold.sample_age_seconds == 30
  end

  # A hold recorded before #2527 carries no stamp. Projecting `0` would claim it
  # was measured this instant, which is the false reassurance the field exists to
  # remove, so it projects as absent instead.
  test "a capacity hold with no stamp projects a nil sample age rather than zero" do
    state = %State{
      capacity_hold: %{
        signal: :load,
        measured: 24.14,
        threshold: 24.0,
        held_since_ms: System.monotonic_time(:millisecond) - 5_000,
        alerted?: true
      }
    }

    snapshot = state |> StatusReport.snapshot_input() |> StatusReport.snapshot_payload()

    assert snapshot.capacity_hold.held?
    assert snapshot.capacity_hold.sample_age_seconds == nil
  end

  test "an absent capacity hold projects a not-held block" do
    snapshot = %State{} |> StatusReport.snapshot_input() |> StatusReport.snapshot_payload()

    assert %{held?: false, signal: nil, threshold: nil, sample_age_seconds: nil} = snapshot.capacity_hold
  end

  test "an old projector cannot replace a same-name orchestrator snapshot" do
    orchestrator_name = Module.concat(__MODULE__, :GenerationFencedSnapshotOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, initial_poll?: false)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    fresh_snapshot = %{running: [], retrying: [], idle: [], marker: :fresh}
    :ok = SnapshotStore.publish(orchestrator_name, fresh_snapshot)

    callback_ref = make_ref()

    assert {:noreply, _store} =
             SnapshotStore.handle_info(
               {:snapshot_built, callback_ref, orchestrator_name, make_ref(), {:ok, %{marker: :stale}, nil}},
               %{pending: %{}, task_ref: callback_ref, monitor_ref: nil, timer_ref: nil}
             )

    assert {:current, snapshot, _freshness} = Orchestrator.dashboard_snapshot(orchestrator_name, 100)
    assert Map.take(snapshot, Map.keys(fresh_snapshot)) == fresh_snapshot
    assert snapshot.globally_paused == false
    assert snapshot.global_pause == %{globally_paused: false, paused_at: nil, source: nil}
  end

  test "an old generation cannot evict a newer pending projection" do
    orchestrator = self()
    current_generation = SnapshotStore.begin_generation(orchestrator)
    stale_generation = make_ref()
    snapshot_input = %State{agent_totals: %{total_tokens: 2}}
    store = %{pending: %{}, task_ref: nil, monitor_ref: nil, timer_ref: nil}

    assert {:noreply, store} =
             SnapshotStore.handle_cast(
               {:publish_state, orchestrator, current_generation, snapshot_input},
               store
             )

    assert {:noreply, stale_store} =
             SnapshotStore.handle_cast(
               {:publish_state, orchestrator, stale_generation, %State{agent_totals: %{total_tokens: 1}}},
               store
             )

    assert stale_store.pending == store.pending
    Process.cancel_timer(store.timer_ref)
  end
end
