defmodule Aiur.Orchestrator.TrackerTasksTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.Orchestrator.{State, TrackerTasks}

  test "duplicate polls coalesce and completion applies to current owner state" do
    owner = self()
    state = %State{snapshot_key: self()}

    fetch = fn ->
      send(owner, {:started, self()})
      receive do: (:release -> :fetched)
    end

    apply_result = fn current, :fetched -> %{current | poll_cycles_completed: current.poll_cycles_completed + 1} end
    pending = TrackerTasks.run(state, :poll, fetch, apply_result)
    duplicate = TrackerTasks.run(pending, :poll, fn -> flunk("duplicate fetch") end, apply_result)
    assert duplicate == pending
    receive_barrier({:started, worker})
    send(worker, :release)
    receive_barrier({ref, :fetched})
    {:handled, next} = TrackerTasks.result(%{pending | globally_paused: true}, ref, :fetched)
    assert next.globally_paused
    assert next.poll_cycles_completed == 1
    assert next.tracker_tasks == %{}
    assert TrackerTasks.result(next, ref, :fetched) == :unhandled
  end

  test "coalesced callers retain distinct continuations in order" do
    owner = self()

    pending =
      TrackerTasks.start(
        %State{},
        :dispatch,
        fn ->
          send(owner, {:started, self()})
          receive do: (:release -> :fetched)
        end,
        fn current, :fetched -> %{current | poll_cycles_completed: 1} end
      )

    duplicate = TrackerTasks.start(pending, :dispatch, fn -> flunk("duplicate fetch") end, fn current, :fetched -> %{current | poll_cycles_completed: current.poll_cycles_completed + 1} end)
    receive_barrier({:started, worker})
    send(worker, :release)
    receive_barrier({ref, :fetched})
    {:handled, next} = TrackerTasks.result(duplicate, ref, :fetched)
    assert next.poll_cycles_completed == 2
    assert next.tracker_tasks == %{}
  end

  test "a reply already received at the deadline preserves its successful outcome" do
    pending = TrackerTasks.start(%State{}, :write, fn -> :written end, fn current, :written -> %{current | globally_paused: true} end)
    [ref] = Map.keys(pending.tracker_tasks)
    receive_barrier({:DOWN, ^ref, :process, _worker, :normal})
    next = TrackerTasks.timeout(pending, ref)
    assert next.globally_paused
    assert next.tracker_tasks == %{}
    refute_received {^ref, :written}
  end

  test "a worker crash clears only its job and reports failure" do
    apply_result = fn state, {:error, {:tracker_task_exit, :controlled_crash}} -> %{state | globally_paused: true} end
    pending = TrackerTasks.start(%State{}, :crash, fn -> exit(:controlled_crash) end, apply_result)
    receive_barrier({:DOWN, ref, :process, _pid, :controlled_crash})
    {:handled, next} = TrackerTasks.down(pending, ref, :controlled_crash)
    assert next.globally_paused
    assert next.tracker_tasks == %{}
  end

  test "timeout cancels the worker and a late result cannot apply twice" do
    owner = self()

    pending =
      TrackerTasks.start(
        %State{},
        :timeout,
        fn ->
          send(owner, {:started, self()})
          receive do: (:never -> :ok)
        end,
        fn state, {:error, :tracker_task_timeout} -> %{state | globally_paused: true} end
      )

    receive_barrier({:started, worker})
    [ref] = Map.keys(pending.tracker_tasks)
    next = TrackerTasks.timeout(pending, ref)
    refute Process.alive?(worker)
    assert next.globally_paused
    assert next.tracker_tasks == %{}
    assert TrackerTasks.result(next, ref, :ok) == :unhandled
    assert TrackerTasks.timeout(next, ref) == next
  end

  test "stop reaps a held tracker task" do
    owner = self()

    pending =
      TrackerTasks.start(
        %State{},
        :held,
        fn ->
          send(owner, {:started, self()})
          receive do: (:never -> :ok)
        end,
        fn state, _ -> state end
      )

    receive_barrier({:started, worker})
    monitor = Process.monitor(worker)

    assert :ok = TrackerTasks.stop(pending)
    receive_barrier({:DOWN, ^monitor, :process, ^worker, :killed})
    refute Process.alive?(worker)
  end
end
