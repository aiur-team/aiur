defmodule Aiur.TrackerTaskDrainSupportTest do
  use ExUnit.Case, async: true

  import Aiur.TrackerTaskDrainSupport, only: [drain_tracker_tasks: 2, drain_tracker_tasks: 3]

  # Stands in for the Orchestrator mid poll cycle: every tracker task that
  # dies or replies makes it start the next one, without end.
  defmodule Owner do
    use GenServer

    def start_link(tasks), do: GenServer.start_link(__MODULE__, tasks)

    def init(tasks), do: {:ok, start_task(%{tracker_tasks: %{}, tasks: tasks, started: 0})}

    def handle_info({:DOWN, ref, :process, _pid, _reason}, state), do: {:noreply, respawn(state, ref)}
    def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, respawn(state, ref)}

    defp respawn(state, ref), do: start_task(%{state | tracker_tasks: Map.delete(state.tracker_tasks, ref)})

    defp start_task(state) do
      task = Task.Supervisor.async_nolink(state.tasks, fn -> Process.sleep(:infinity) end)
      job = %{key: :dispatch_poll, task: task, timer: nil}
      %{state | tracker_tasks: Map.put(state.tracker_tasks, task.ref, job), started: state.started + 1}
    end
  end

  defmodule SlowOwner do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

    def init(parent) do
      {:ok, %{parent: parent, tracker_tasks: %{make_ref() => %{key: {:comment_idle, "500", "issue comment"}}}}}
    end

    def handle_info(:block, state) do
      send(state.parent, :owner_blocked)
      Process.sleep(30)
      {:noreply, state}
    end
  end

  test "drains an owner that starts another task whenever one ends" do
    tasks = start_supervised!(Task.Supervisor)
    owner = start_supervised!({Owner, tasks})
    [task_pid] = Task.Supervisor.children(tasks)

    assert :ok = drain_tracker_tasks(owner, 5_000)

    assert %{tracker_tasks: tracker_tasks, started: 1} = :sys.get_state(owner)
    assert tracker_tasks == %{}
    refute Process.alive?(task_pid)
    assert Task.Supervisor.children(tasks) == []
  end

  test "a timed-out drain names its test and clears the held set for the next test" do
    owner = start_supervised!({SlowOwner, self()})
    send(owner, :block)
    assert_receive :owner_blocked, 1_000

    assert_raise RuntimeError, ~r/during failing test; held: \[\{:comment_idle, \"500\", \"issue comment\"\}\]/, fn ->
      drain_tracker_tasks(owner, 5, "failing test")
    end

    assert %{tracker_tasks: %{}} = :sys.get_state(owner)
  end
end
