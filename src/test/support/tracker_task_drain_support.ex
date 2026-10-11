defmodule Aiur.TrackerTaskDrainSupport do
  @moduledoc false

  alias Aiur.Orchestrator.TrackerTasks

  @doc """
  Shuts down an Orchestrator's tracker tasks and drops them from its state.

  The shutdown runs inside the owner, so the owner never applies a result for
  a stopped task. Killing a task from outside made the owner apply its error
  result, and a poll cycle continues from that result by starting the next
  `:dispatch_poll` task, so a kill loop could chase the chain past its bound
  (#3957, #4070). An owner that does not answer within the timeout exits the
  caller. If the owner does not answer, forget the stale set before failing so
  the next test does not fail on the same held task.
  """
  @spec drain_tracker_tasks(pid(), non_neg_integer()) :: :ok
  def drain_tracker_tasks(pid, timeout_ms \\ 15_000) do
    drain_tracker_tasks(pid, timeout_ms, "unknown test")
  end

  @spec drain_tracker_tasks(pid(), non_neg_integer(), String.t()) :: :ok
  def drain_tracker_tasks(pid, timeout_ms, test_name) do
    :sys.replace_state(
      pid,
      fn state ->
        :ok = TrackerTasks.stop(state)
        %{state | tracker_tasks: %{}}
      end,
      timeout_ms
    )

    :ok
  catch
    :exit, reason ->
      held = held_tasks(pid)
      clear_tracker_tasks(pid)
      raise "Timed out draining orchestrator tracker tasks during #{test_name}; held: #{inspect(held)}; reason: #{inspect(reason)}"
  end

  defp clear_tracker_tasks(pid) do
    :sys.replace_state(pid, &%{&1 | tracker_tasks: %{}}, 100)
  catch
    :exit, _reason -> :ok
  end

  defp held_tasks(pid) do
    pid
    |> :sys.get_state(100)
    |> Map.get(:tracker_tasks, %{})
    |> Enum.map(fn {_ref, job} -> Map.get(job, :key, :unknown) end)
  catch
    :exit, _reason -> [:owner_unresponsive]
  end
end
