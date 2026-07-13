defmodule Aiur.Orchestrator.LifecycleTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{Lifecycle, State, TrackedSet}

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

  test "orchestrator accepts a protected tick token" do
    token = make_ref()

    state = %State{
      tick_timer_ref: make_ref(),
      tick_token: {:budget_protected, token},
      next_poll_due_at_ms: System.monotonic_time(:millisecond),
      poll_check_in_progress: false
    }

    assert {:noreply, next} =
             Orchestrator.handle_info({:tick, {:budget_protected, token}}, state)

    assert next.poll_check_in_progress
    assert is_nil(next.tick_token)
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

  test "request_refresh respects a protective GitHub budget delay" do
    old_timer = Process.send_after(self(), :unprotected_tick, 1_000)

    state = %State{
      next_poll_due_at_ms: System.monotonic_time(:millisecond) + 1_000,
      poll_check_in_progress: false,
      tick_timer_ref: old_timer,
      tick_token: make_ref()
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed} =
             Lifecycle.request_refresh(state, budget_delay_fun: fn -> 5_000 end)

    assert refreshed.next_poll_due_at_ms > System.monotonic_time(:millisecond) + 4_000
    refute refreshed.tick_timer_ref == old_timer
    assert {:budget_protected, protected_token} = refreshed.tick_token
    assert is_reference(protected_token)

    assert {:reply, %{queued: true, coalesced: true}, coalesced} =
             Lifecycle.request_refresh(refreshed, budget_delay_fun: fn -> 5_000 end)

    assert coalesced.tick_timer_ref == refreshed.tick_timer_ref
    assert coalesced.tick_token == refreshed.tick_token
    assert coalesced.next_poll_due_at_ms == refreshed.next_poll_due_at_ms

    Process.cancel_timer(coalesced.tick_timer_ref)
    refute_receive :unprotected_tick
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
end
