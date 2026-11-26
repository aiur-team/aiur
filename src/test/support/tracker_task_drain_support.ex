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
  caller. A timed-out system request can still run later, so it only stops and
  removes the task references captured before the request.
  """
  @spec drain_tracker_tasks(pid(), non_neg_integer()) :: :ok
  def drain_tracker_tasks(pid, timeout_ms \\ 15_000) do
    drain_tracker_tasks(pid, timeout_ms, "unknown test", :current)
  end

  @spec drain_tracker_tasks(pid(), non_neg_integer(), String.t()) :: :ok
  def drain_tracker_tasks(pid, timeout_ms, test_name) do
    drain_tracker_tasks(pid, timeout_ms, test_name, :current)
  end

  @spec drain_tracker_tasks(pid(), non_neg_integer(), String.t(), map() | :current) :: :ok
  def drain_tracker_tasks(pid, timeout_ms, test_name, tasks) do
    held =
      try do
        if tasks == :current, do: :sys.get_state(pid, timeout_ms).tracker_tasks, else: tasks
      catch
        :exit, {:timeout, _} = reason ->
          raise "Timed out draining orchestrator tracker tasks during #{test_name}; held: [:owner_unresponsive]; reason: #{inspect(reason)}"

        :exit, reason ->
          raise "Failed draining orchestrator tracker tasks during #{test_name}; reason: #{inspect(reason)}"
      end

    try do
      :sys.replace_state(
        pid,
        fn state ->
          :ok = TrackerTasks.stop(%{state | tracker_tasks: held})
          %{state | tracker_tasks: Map.drop(state.tracker_tasks, Map.keys(held))}
        end,
        timeout_ms
      )

      :ok
    catch
      :exit, {:timeout, _} = reason ->
        keys = if is_map(held), do: Enum.map(held, fn {_ref, job} -> job.key end), else: [:owner_unresponsive]
        raise "Timed out draining orchestrator tracker tasks during #{test_name}; held: #{inspect(keys)}; reason: #{inspect(reason)}"

      :exit, reason ->
        raise "Failed draining orchestrator tracker tasks during #{test_name}; reason: #{inspect(reason)}"
    end
  end
end
