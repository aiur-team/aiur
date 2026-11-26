defmodule Aiur.Orchestrator.OrphanedWorkersWakeTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.{Lifecycle, OrphanedWorkers, State}
  alias Aiur.Workspace.Ownership

  # The scan runs inside the Orchestrator; here the test process plays that
  # role, so each runner below reports to this process. Every running-map
  # shape that names the ticket or the runner pid must keep the runner alive.
  describe "running-map shapes" do
    for {shape, entry_fun} <- [
          {"working", quote(do: fn runner -> %{pid: runner, control: %{status: :working}} end)},
          {"paused", quote(do: fn runner -> %{pid: runner, control: %{status: :paused}} end)},
          {"pause pending", quote(do: fn runner -> %{pid: runner, control: %{status: :working}, pending_pause_reason: %{request_id: 1}} end)},
          {"sleeping", quote(do: fn runner -> %{pid: runner, control: %{status: :sleeping}, work_state: :sleeping} end)},
          {"completed", quote(do: fn runner -> %{pid: runner, control: %{status: :completed}, completed_provenance: true} end)},
          {"pause pending, no pid", quote(do: fn _runner -> %{pid: nil, control: %{status: :working}, pending_pause_reason: %{request_id: 1}} end)},
          {"staged", quote(do: fn _runner -> %{pid: nil, redispatch_safety: %{workspace_path: "/w"}, control: %{status: :working}} end)},
          {"replaced", quote(do: fn _runner -> %{pid: spawn(fn -> Process.sleep(:infinity) end), control: %{status: :working}} end)}
        ] do
      test "#{shape} entry" do
        identifier = "ORPH-SHAPE-#{System.unique_integer([:positive])}"
        issue_id = "issue-#{identifier}"
        runner = claim_in_process(identifier, %{issue_id: issue_id, update_recipient: self(), worker_host: nil})
        {:ok, lease} = Ownership.current(identifier)

        entry = Map.put(unquote(entry_fun).(runner), :identifier, identifier)
        state = OrphanedWorkers.stop_untracked_runners(%State{running: %{issue_id => entry}})

        assert Process.alive?(runner)
        assert {:ok, ^lease} = Ownership.current(identifier)
        assert state.running == %{issue_id => entry}
      end
    end

    test "an entry under another ticket id that names the runner pid" do
      identifier = "ORPH-SHAPE-#{System.unique_integer([:positive])}"
      runner = claim_in_process(identifier, %{issue_id: "issue-#{identifier}", update_recipient: self(), worker_host: nil})
      {:ok, lease} = Ownership.current(identifier)

      running = %{"issue-renamed" => %{pid: runner, identifier: identifier, control: %{status: :working}}}
      _state = OrphanedWorkers.stop_untracked_runners(%State{running: running})

      assert Process.alive?(runner)
      assert {:ok, ^lease} = Ownership.current(identifier)
    end

    # Deactivation and completion kill the runner synchronously, so a live
    # lease holder beside such an entry is always an orphan.
    for {shape, entry} <- [
          {"deactivated, no pid", Macro.escape(%{pid: nil, ref: nil, control: %{status: :deactivated}})},
          {"completed, no pid", Macro.escape(%{pid: nil, ref: nil, control: %{status: :completed}, completed_provenance: true})}
        ] do
      test "#{shape} entry does not protect a live lease holder" do
        identifier = "ORPH-SHAPE-#{System.unique_integer([:positive])}"
        issue_id = "issue-#{identifier}"
        runner = claim_in_process(identifier, %{issue_id: issue_id, update_recipient: self(), worker_host: nil})
        ref = Process.monitor(runner)
        entry = Map.put(unquote(entry), :identifier, identifier)

        state = OrphanedWorkers.stop_untracked_runners(%State{running: %{issue_id => entry}})

        assert_receive {:DOWN, ^ref, :process, ^runner, _reason}, 5_000
        assert state.running == %{issue_id => entry}
      end
    end

    test "an entry whose pid is dead does not protect a live lease holder" do
      identifier = "ORPH-SHAPE-#{System.unique_integer([:positive])}"
      issue_id = "issue-#{identifier}"
      runner = claim_in_process(identifier, %{issue_id: issue_id, update_recipient: self(), worker_host: nil})
      ref = Process.monitor(runner)
      dead = spawn(fn -> :ok end)
      dead_ref = Process.monitor(dead)
      assert_receive {:DOWN, ^dead_ref, :process, ^dead, _reason}, 1000

      entry = %{pid: dead, identifier: identifier, control: %{status: :working}}
      _state = OrphanedWorkers.stop_untracked_runners(%State{running: %{issue_id => entry}})

      assert_receive {:DOWN, ^ref, :process, ^runner, _reason}, 5_000
    end

    test "no entry at all: the runner is stopped (control)" do
      identifier = "ORPH-SHAPE-#{System.unique_integer([:positive])}"
      runner = claim_in_process(identifier, %{issue_id: "issue-#{identifier}", update_recipient: self(), worker_host: nil})
      ref = Process.monitor(runner)

      state = OrphanedWorkers.stop_untracked_runners(%State{})

      assert_receive {:DOWN, ^ref, :process, ^runner, _reason}, 5_000
      assert Map.has_key?(state.dispatch_recovery.workspace_ownership.waits, identifier)
    end
  end

  describe "a released workspace wakes the tick only under the tick policy" do
    test "no pending tick timer: nothing is scheduled" do
      state = %State{tick_timer_ref: nil, tick_token: nil}
      assert Lifecycle.wake_tick(state) == state
    end

    test "a frozen poll: the pending timer is left alone" do
      state = pending_tick_state(60_000, poll_frozen: true)
      assert Lifecycle.wake_tick(state) == state
      assert is_integer(Process.read_timer(state.tick_timer_ref))
    end

    test "a tick due sooner than the GitHub floor allows is never delayed" do
      state = pending_tick_state(5_000, github_poll_delays: %{firehose: 60_000}, polled_ago_ms: 0)
      assert Lifecycle.wake_tick(state) == state
      assert Process.read_timer(state.tick_timer_ref) > 4_000
    end

    test "a later tick is pulled forward, but not ahead of the floor measured from the last poll" do
      state = pending_tick_state(300_000, github_poll_delays: %{firehose: 60_000}, polled_ago_ms: 10_000)
      woken = Lifecycle.wake_tick(state)

      assert woken.tick_timer_ref != state.tick_timer_ref
      assert Process.read_timer(state.tick_timer_ref) == false
      assert Process.read_timer(woken.tick_timer_ref) in 45_000..50_000
      Process.cancel_timer(woken.tick_timer_ref)
    end

    test "a later tick is pulled to now once the floor since the last poll has passed" do
      state = pending_tick_state(300_000, github_poll_delays: %{firehose: 60_000}, polled_ago_ms: 120_000)
      woken = Lifecycle.wake_tick(state)

      assert Process.read_timer(woken.tick_timer_ref) in [false | Enum.to_list(0..100)]
      Process.cancel_timer(woken.tick_timer_ref)
    end
  end

  defp pending_tick_state(due_in_ms, opts) do
    now_ms = System.monotonic_time(:millisecond)
    timer = Process.send_after(self(), :never, due_in_ms)
    on_exit(fn -> Process.cancel_timer(timer) end)

    last_poll =
      case Keyword.fetch(opts, :polled_ago_ms) do
        {:ok, ago} -> now_ms - ago
        :error -> nil
      end

    %State{
      tick_timer_ref: timer,
      tick_token: make_ref(),
      next_poll_due_at_ms: now_ms + due_in_ms,
      poll_frozen: Keyword.get(opts, :poll_frozen, false),
      github_poll_delays: Keyword.get(opts, :github_poll_delays, %{}),
      last_dispatch_poll_at_ms: last_poll
    }
  end

  defp claim_in_process(identifier, holder) do
    parent = self()

    owner =
      spawn(fn ->
        send(parent, {:claimed, Ownership.claim(identifier, Aiur.Workspace.Ownership.Registry, holder: holder)})
        Process.sleep(:infinity)
      end)

    assert_receive {:claimed, {:ok, _lease}}, 5_000
    on_exit(fn -> Process.exit(owner, :kill) end)
    owner
  end
end
