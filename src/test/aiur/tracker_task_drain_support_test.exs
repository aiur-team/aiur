defmodule Aiur.TrackerTaskDrainSupportTest do
  use ExUnit.Case, async: true

  import Aiur.TrackerTaskDrainSupport, only: [drain_tracker_tasks: 2]

  # Stands in for the Orchestrator: it holds tracker tasks and, like a retried
  # tracker read, starts another task when one dies, `respawns` times.
  defmodule Owner do
    use GenServer

    def start_link(respawns), do: GenServer.start_link(__MODULE__, respawns)

    def init(respawns), do: {:ok, start_task(%{tracker_tasks: %{}, respawns: respawns})}

    def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
      state = %{state | tracker_tasks: Map.delete(state.tracker_tasks, ref)}

      case state.respawns do
        0 -> {:noreply, state}
        :infinity -> {:noreply, start_task(state)}
        count -> {:noreply, start_task(%{state | respawns: count - 1})}
      end
    end

    defp start_task(state) do
      {pid, ref} = spawn_monitor(fn -> Process.sleep(:infinity) end)
      job = %{key: {:poll, map_size(state.tracker_tasks)}, task: %{pid: pid}}
      %{state | tracker_tasks: Map.put(state.tracker_tasks, ref, job)}
    end
  end

  test "drains a task that respawns after the first kill pass" do
    owner = start_supervised!({Owner, 2})

    assert :ok = drain_tracker_tasks(owner, 5_000)
    assert :sys.get_state(owner).tracker_tasks == %{}
  end

  test "a timeout names the tracker task keys still held" do
    owner = start_supervised!({Owner, :infinity})

    error = assert_raise RuntimeError, fn -> drain_tracker_tasks(owner, 50) end
    assert error.message =~ "still held: [poll: 0]"
  end
end
