defmodule Aiur.Orchestrator.TrackerTasksTest do
  use ExUnit.Case, async: true

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
    assert_receive {:started, worker}
    send(worker, :release)
    assert_receive {ref, :fetched}
    {:handled, next} = TrackerTasks.result(%{pending | globally_paused: true}, ref, :fetched)
    assert next.globally_paused
    assert next.poll_cycles_completed == 1
    assert next.tracker_tasks == %{}
    assert TrackerTasks.result(next, ref, :fetched) == :unhandled
  end

  test "a worker crash clears only its job and reports failure" do
    apply_result = fn state, {:error, {:tracker_task_exit, :controlled_crash}} -> %{state | globally_paused: true} end
    pending = TrackerTasks.start(%State{}, :crash, fn -> exit(:controlled_crash) end, apply_result)
    assert_receive {:DOWN, ref, :process, _pid, :controlled_crash}
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

    assert_receive {:started, worker}
    [ref] = Map.keys(pending.tracker_tasks)
    next = TrackerTasks.timeout(pending, ref)
    refute Process.alive?(worker)
    assert next.globally_paused
    assert next.tracker_tasks == %{}
    assert TrackerTasks.result(next, ref, :ok) == :unhandled
    assert TrackerTasks.timeout(next, ref) == next
  end
end
