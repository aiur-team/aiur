defmodule Aiur.TrackerTaskDrainSupport do
  @moduledoc false

  @doc """
  Kills an Orchestrator's tracker tasks until none are left.

  Killing a task makes the owner apply its error result, and that result can
  start another tracker task. One kill pass then leaves the new task running
  (#3957), so this kills every pass until the owner holds no task. A timeout
  names the keys still held.
  """
  @spec drain_tracker_tasks(pid(), non_neg_integer()) :: :ok
  def drain_tracker_tasks(pid, timeout_ms \\ 15_000) do
    drain(pid, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp drain(pid, deadline) do
    jobs = pid |> :sys.get_state() |> Map.fetch!(:tracker_tasks) |> Map.values()

    cond do
      jobs == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "Timed out draining orchestrator tracker tasks; still held: #{inspect(Enum.map(jobs, & &1.key))}"

      true ->
        Enum.each(jobs, &kill_and_await(&1.task.pid, deadline))
        drain(pid, deadline)
    end
  end

  defp kill_and_await(task_pid, deadline) do
    ref = Process.monitor(task_pid)
    Process.exit(task_pid, :kill)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> Process.demonitor(ref, [:flush])
    end
  end
end
