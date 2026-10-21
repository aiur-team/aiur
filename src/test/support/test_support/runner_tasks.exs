defmodule Aiur.TestSupport.RunnerTasks do
  @moduledoc false

  # Agent runner tasks run under the app-level `Aiur.TaskSupervisor`, not linked
  # to the test that dispatched them. One left running keeps reaching
  # `RepoBase.ensure_state_tree/1` through workspace hooks, so it writes
  # `test-org/test-repo/.aiur-hex` into whatever `:repo_base_root` a later test
  # has bound, even while that test deletes it (#5104).

  alias Aiur.Orchestrator.Dispatcher.Launch

  @doc "Returns the agent runner tasks alive now."
  @spec capture() :: MapSet.t(pid())
  def capture, do: MapSet.new(runner_tasks())

  @doc "Stops every agent runner task started since `capture/0` returned `before`."
  @spec stop_started_since(MapSet.t(pid())) :: :ok
  def stop_started_since(before) do
    for pid <- runner_tasks(), not MapSet.member?(before, pid) do
      # terminate_child/2 returns only after the task has exited.
      _ = Task.Supervisor.terminate_child(Aiur.TaskSupervisor, pid)
    end

    :ok
  end

  @doc "Fails the suite if a runner task outlives the test support fixture."
  @spec verify_suite!() :: :ok
  def verify_suite! do
    case runner_tasks() do
      [] -> :ok
      pids -> raise "test suite found runner tasks still alive after fixture teardown: #{inspect(pids)}"
    end
  end

  @doc "Stops the runner tasks started since `before`, then removes `root`."
  @spec stop_started_since_and_rm_rf!(Path.t(), MapSet.t(pid())) :: :ok
  def stop_started_since_and_rm_rf!(root, before) do
    :ok = stop_started_since(before)
    Aiur.TestCleanup.rm_rf!(root)
  end

  defp runner_tasks do
    if Process.whereis(Aiur.TaskSupervisor) do
      Enum.filter(Task.Supervisor.children(Aiur.TaskSupervisor), &runner_task?/1)
    else
      []
    end
  end

  defp runner_task?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> match?({Launch, _, _}, Keyword.get(dictionary, :"$initial_call"))
      nil -> false
    end
  end
end
