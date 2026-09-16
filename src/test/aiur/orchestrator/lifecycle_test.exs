defmodule Aiur.Orchestrator.LifecycleTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{ControlLifecycle, Lifecycle, SnapshotPublisher, State, StatusReport, TrackedSet}
  alias Aiur.TrackerIdentity

  test "orchestrator subscribes to explicit unblock readiness" do
    topics = Lifecycle.orchestrator_topics()

    assert "ticket.*.agent.unblocked" in topics
    assert "ticket.*.branch.push" in topics
  end

  test "schedule_tick replaces the timer with a new token" do
    old_token = make_ref()
    old_timer = Process.send_after(self(), :superseded_tick, 60_000)

    state = %State{tick_timer_ref: old_timer, tick_token: old_token}
    next = Lifecycle.schedule_tick(state, 0)

    assert is_reference(next.tick_timer_ref)
    assert is_reference(next.tick_token)
    refute next.tick_token == old_token
    assert_receive {:tick, token}
    assert token == next.tick_token
    refute_receive :superseded_tick
  end

  test "handle_tick clears the clock and starts one poll cycle" do
    state = %State{
      tick_timer_ref: make_ref(),
      tick_token: make_ref(),
      next_poll_due_at_ms: System.monotonic_time(:millisecond) + 30_000,
      poll_check_in_progress: false
    }

    assert {:noreply, next} = Lifecycle.handle_tick(state)
    assert next.poll_check_in_progress
    assert is_nil(next.tick_timer_ref)
    assert is_nil(next.tick_token)
    assert is_nil(next.next_poll_due_at_ms)
    assert_receive :run_poll_cycle, 2_000
  end

  test "handle_tick expires overdue control requests without changing worker state" do
    path = Aiur.TestSupport.tmp_root!("aiur-control-lifecycle") <> ".json"
    previous_path = Application.get_env(:aiur, :control_lifecycle_store_path)
    Application.put_env(:aiur, :control_lifecycle_store_path, path)

    on_exit(fn ->
      if is_nil(previous_path),
        do: Application.delete_env(:aiur, :control_lifecycle_store_path),
        else: Application.put_env(:aiur, :control_lifecycle_store_path, previous_path)

      File.rm(path)
    end)

    requested_at = DateTime.add(DateTime.utc_now(), -31, :second)
    lifecycle = ControlLifecycle.new(now: requested_at)

    {:ok, _request, lifecycle} =
      ControlLifecycle.request(
        lifecycle,
        %{
          request_id: "pause-1",
          issue_id: "issue-1",
          tracker_identity: tracker_identity(),
          action: :pause,
          generation: 1,
          expected_status: :working,
          expected_version: 0,
          requester: :operator
        },
        now: requested_at
      )

    {:ok, _accepted, lifecycle} = ControlLifecycle.accept(lifecycle, "pause-1", 1, now: requested_at)

    state = %State{
      control_lifecycle: lifecycle,
      running: %{"issue-1" => %{identifier: "owner/repo#1", control: %{status: :working}}},
      tick_timer_ref: make_ref(),
      tick_token: make_ref(),
      next_poll_due_at_ms: System.monotonic_time(:millisecond) + 30_000,
      poll_check_in_progress: false
    }

    assert {:noreply, next} = Lifecycle.handle_tick(state)
    assert %{status: :expired, expiry: %{reason: :timeout}} = ControlLifecycle.get(next.control_lifecycle, "pause-1")
    assert next.running["issue-1"].control.status == :working
    assert_receive :run_poll_cycle, 2_000
  end

  test "request_refresh coalesces once an immediate tick is due" do
    state = %State{
      next_poll_due_at_ms: System.monotonic_time(:millisecond) + 30_000,
      poll_check_in_progress: false
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed} =
             Lifecycle.request_refresh(state)

    assert {:reply, %{queued: true, coalesced: true}, coalesced} =
             Lifecycle.request_refresh(refreshed)

    assert coalesced.tick_token == refreshed.tick_token
    assert_receive {:tick, token}
    assert token == refreshed.tick_token
  end

  # Acceptance criterion 1 of #2365, measured rather than asserted: a wake
  # arriving during a long idle backoff must collapse the widened
  # `next_poll_due_at_ms` to now (an immediate tick), not wait out the rest of
  # the backoff. No GitHub floor recorded => the wake is immediate.
  test "a wake interrupts a widened idle backoff by collapsing the next poll to now" do
    state = %State{
      next_poll_due_at_ms: System.monotonic_time(:millisecond) + 600_000,
      poll_check_in_progress: false,
      github_poll_delays: %{}
    }

    {refreshed, coalesced} = Lifecycle.request_refresh_state(state)

    refute coalesced
    assert refreshed.next_poll_due_at_ms <= System.monotonic_time(:millisecond)
    assert_receive {:tick, token}
    assert token == refreshed.tick_token
  end

  # The same wake must never schedule the cycle ahead of the GitHub rate-limit
  # floor: the cycle it schedules fetches from GitHub, so scheduling it sooner
  # than the floor would let an externally-triggered wake force a full fetch
  # outside the floor the orchestrator computed for itself (#2365 review #3).
  test "a wake never schedules ahead of the GitHub rate-limit floor" do
    now = System.monotonic_time(:millisecond)

    state = %State{
      next_poll_due_at_ms: now + 600_000,
      poll_check_in_progress: false,
      github_poll_delays: %{poll: 30_000}
    }

    {refreshed, coalesced} = Lifecycle.request_refresh_state(state)

    refute coalesced
    assert refreshed.next_poll_due_at_ms >= now + 30_000
    refute_receive {:tick, _token}, 100
  end

  # `aiur --todo` on an idle, backed-off fleet: the wake collapses the widened
  # timer to now AND records the queued identifiers, so the woken poll — and
  # one follow-up — stay at the base interval even if the tracker has not yet
  # shown the ticket (#2640).
  test "note_queued_demand records the tickets and collapses a widened backoff to now" do
    state = %State{
      next_poll_due_at_ms: System.monotonic_time(:millisecond) + 600_000,
      poll_check_in_progress: false,
      poll_cycles_completed: 1,
      github_poll_delays: %{}
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed} =
             Lifecycle.note_queued_demand(state, ["3", 4, ""])

    assert refreshed.queued_demand_hints == %{"3" => 3, "4" => 3}
    assert refreshed.next_poll_due_at_ms <= System.monotonic_time(:millisecond)
    assert_receive {:tick, token}
    assert token == refreshed.tick_token
  end

  test "the orchestrator answers note_queued_demand with the refresh receipt" do
    state = %State{
      next_poll_due_at_ms: System.monotonic_time(:millisecond) + 600_000,
      poll_check_in_progress: false,
      poll_cycles_completed: 1,
      github_poll_delays: %{}
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed} =
             Orchestrator.handle_call({:note_queued_demand, ["3"]}, {self(), make_ref()}, state)

    assert refreshed.queued_demand_hints == %{"3" => 3}
    assert refreshed.next_poll_due_at_ms <= System.monotonic_time(:millisecond)
    assert_receive {:tick, _token}
  end

  test "a refresh publishes the collapsed countdown before its poll runs" do
    key = self()
    on_exit(fn -> SnapshotPublisher.clear(key) end)

    state = %State{
      snapshot_key: key,
      snapshot_ready?: true,
      candidate_snapshot_fresh?: true,
      next_poll_due_at_ms: System.monotonic_time(:millisecond) + 600_000,
      poll_check_in_progress: false,
      poll_cycles_completed: 1,
      github_poll_delays: %{}
    }

    StatusReport.notify_dashboard(state)
    [{^key, _, old_version, old_input}] = :ets.lookup(SnapshotPublisher, key)
    assert old_input.next_poll_due_at_ms == state.next_poll_due_at_ms

    assert {:reply, %{coalesced: false}, refreshed} =
             Orchestrator.handle_call({:note_queued_demand, ["3"]}, {self(), make_ref()}, state)

    # The write is synchronous before handle_call returns. The unique producer
    # key prevents another test or the periodic publisher satisfying this check.
    [{^key, _, new_version, new_input}] = :ets.lookup(SnapshotPublisher, key)
    assert new_version > old_version
    assert new_input.next_poll_due_at_ms == refreshed.next_poll_due_at_ms
    assert new_input.next_poll_due_at_ms < old_input.next_poll_due_at_ms
    assert_receive {:tick, token}
    assert token == refreshed.tick_token
  end

  test "note_queued_demand_api reports an unreachable orchestrator instead of raising" do
    assert Lifecycle.note_queued_demand_api(:"no-such-orchestrator-#{System.unique_integer([:positive])}", ["3"]) ==
             :unavailable
  end

  test "a GitHub quota recovery signal queues an immediate admission poll" do
    state = %State{
      capacity_hold: %{
        signal: :github_quota,
        measured: %{resource: "graphql", remaining: 0, limit: 5000},
        threshold: :ten_percent_remaining,
        held_since_ms: System.monotonic_time(:millisecond),
        alerted?: false
      },
      next_poll_due_at_ms: System.monotonic_time(:millisecond) + 30_000,
      poll_check_in_progress: false
    }

    assert {:noreply, refreshed} = Orchestrator.handle_info(:github_quota_recovered, state)
    assert is_reference(refreshed.tick_token)
    assert refreshed.next_poll_due_at_ms <= System.monotonic_time(:millisecond)
    assert_receive {:tick, token}
    assert token == refreshed.tick_token
  end

  test "tracked-set refresh excludes deactivated entries" do
    state = %State{
      running: %{
        "working" => %{identifier: "943", control: %{status: :working}},
        "finished" => %{identifier: "944", control: %{status: :deactivated}}
      }
    }

    assert ^state = TrackedSet.refresh(state)
    assert TrackedSet.member?("943")
    refute TrackedSet.member?("944")
  end

  defp tracker_identity do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "I_kwDOissue1",
      identifier: "1",
      reason: nil
    }
  end
end
