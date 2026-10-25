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
  def capture, do: capture(Aiur.TaskSupervisor)

  @doc false
  @spec capture(GenServer.server()) :: MapSet.t(pid())
  def capture(supervisor), do: MapSet.new(runner_tasks(supervisor))

  @doc "Stops every agent runner task started since `capture/0` returned `before`."
  @spec stop_started_since(MapSet.t(pid())) :: :ok
  def stop_started_since(before) do
    for pid <- runner_tasks(), not MapSet.member?(before, pid) do
      # terminate_child/2 returns only after the task has exited.
      _ = Task.Supervisor.terminate_child(Aiur.TaskSupervisor, pid)
    end

    :ok
  catch
    # The supervisor shut down mid-loop and took the remaining tasks with it.
    :exit, _reason -> :ok
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

  defp runner_tasks(supervisor \\ Aiur.TaskSupervisor) do
    Enum.filter(Task.Supervisor.children(supervisor), &runner_task?/1)
  catch
    # Absent, or shut down by a :rest_for_one restart while we asked (#5581): its tasks exited with it.
    :exit, _reason -> []
  end

  defp runner_task?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> match?({Launch, _, _}, Keyword.get(dictionary, :"$initial_call"))
      nil -> false
    end
  end
end
