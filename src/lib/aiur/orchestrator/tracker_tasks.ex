defmodule Aiur.Orchestrator.TrackerTasks do
  @moduledoc false

  alias Aiur.Orchestrator.State

  @timeout_ms 120_000

  @spec owner?(State.t()) :: boolean()
  def owner?(state), do: not is_nil(state.snapshot_key) and GenServer.whereis(state.snapshot_key) == self()

  @spec run(State.t(), term(), (-> term()), (State.t(), term() -> State.t())) :: State.t()
  def run(state, key, fetch, apply_result) do
    if owner?(state), do: start(state, key, fetch, apply_result), else: apply_result.(state, fetch.())
  end

  @spec running?(State.t(), term()) :: boolean()
  def running?(state, key), do: Enum.any?(state.tracker_tasks, fn {_ref, job} -> job.key == key end)

  @spec issue_pending?(State.t(), term()) :: boolean()
  def issue_pending?(state, id) do
    Enum.any?(state.tracker_tasks, fn
      {_ref, %{key: {_kind, ^id}}} -> true
      _ -> false
    end)
  end

  @spec start(State.t(), term(), (-> term()), (State.t(), term() -> State.t())) :: State.t()
  def start(%State{} = state, key, fetch, apply_result) do
    if running?(state, key) do
      state
    else
      task = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fetch)
      timer = Process.send_after(self(), {:tracker_task_timeout, task.ref}, @timeout_ms)
      job = %{task: task, key: key, timer: timer, apply: apply_result}
      %{state | tracker_tasks: Map.put(state.tracker_tasks, task.ref, job)}
    end
  end

  @spec result(State.t(), reference(), term()) :: {:handled, State.t()} | :unhandled
  def result(%State{} = state, ref, result) do
    case Map.pop(state.tracker_tasks, ref) do
      {nil, _jobs} ->
        :unhandled

      {job, jobs} ->
        Process.cancel_timer(job.timer)
        Process.demonitor(ref, [:flush])
        {:handled, job.apply.(%{state | tracker_tasks: jobs}, result)}
    end
  end

  @spec down(State.t(), reference(), term()) :: {:handled, State.t()} | :unhandled
  def down(state, ref, reason), do: result(state, ref, {:error, {:tracker_task_exit, reason}})

  @spec timeout(State.t(), reference()) :: State.t()
  def timeout(state, ref) do
    case Map.get(state.tracker_tasks, ref) do
      nil ->
        state

      job ->
        Task.shutdown(job.task, :brutal_kill)
        {:handled, state} = result(state, ref, {:error, :tracker_task_timeout})
        state
    end
  end

  @spec stop(State.t()) :: :ok
  def stop(state) do
    Enum.each(state.tracker_tasks, fn {_ref, job} ->
      Process.cancel_timer(job.timer)
      Task.shutdown(job.task, :brutal_kill)
    end)

    :ok
  end
end
