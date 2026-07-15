defmodule Aiur.Orchestrator.LifecycleTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.{ControlLifecycle, Lifecycle, State, TrackedSet}
  alias Aiur.TrackerIdentity

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
    path = Path.join(System.tmp_dir!(), "aiur-control-lifecycle-#{System.unique_integer([:positive])}.json")
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
