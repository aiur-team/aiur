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
  caller.
  """
  @spec drain_tracker_tasks(pid(), non_neg_integer()) :: :ok
  def drain_tracker_tasks(pid, timeout_ms \\ 15_000) do
    :sys.replace_state(
      pid,
      fn state ->
        :ok = TrackerTasks.stop(state)
        %{state | tracker_tasks: %{}}
      end,
      timeout_ms
    )

    :ok
  end
end
