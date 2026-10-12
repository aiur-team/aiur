defmodule Aiur.Orchestrator.TrackerTasks do
  @moduledoc false

  alias Aiur.Orchestrator.State

  @timeout_ms 120_000

  @spec same_runner?(map() | nil, map() | nil) :: boolean()
  def same_runner?(current, expected) when is_map(current) and is_map(expected) do
    fields = [:pid, :ref, :session_id, :telemetry_attempt_id, :control, :issue]
    Map.take(current, fields) == Map.take(expected, fields)
  end

  def same_runner?(nil, nil), do: true
  def same_runner?(_, _), do: false

  @spec owner?(State.t()) :: boolean()
  def owner?(state), do: not is_nil(state.snapshot_key) and GenServer.whereis(state.snapshot_key) == self()

  @spec run(State.t(), term(), (-> term()), (State.t(), term() -> State.t())) :: State.t()
  def run(state, key, fetch, apply_result) do
    if owner?(state), do: start(state, key, fetch, apply_result), else: apply_result.(state, fetch.())
  end

  # Like `run/4`, but a job already running for `key` is followed by this one instead of
  # absorbing it, so same-key work keeps its submission order.
  @spec chain(State.t(), term(), (-> term()), (State.t(), term() -> State.t())) :: State.t()
  def chain(state, key, fetch, apply_result) do
    if owner?(state) and running?(state, key) do
      retain_completion(state, key, fn current, _result -> chain(current, key, fetch, apply_result) end)
    else
      run(state, key, fetch, apply_result)
    end
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
      retain_completion(state, key, apply_result)
    else
      task = Task.Supervisor.async_nolink(Aiur.TaskSupervisor, fetch)
      timer = task_timer(key, task.ref)
      job = %{task: task, key: key, timer: timer, apply: [apply_result]}
      %{state | tracker_tasks: Map.put(state.tracker_tasks, task.ref, job)}
    end
  end

  @spec result(State.t(), reference(), term()) :: {:handled, State.t()} | :unhandled
  def result(%State{} = state, ref, result) do
    case Map.pop(state.tracker_tasks, ref) do
      {nil, _jobs} ->
        :unhandled

      {job, jobs} ->
        cancel_timer(job.timer)
        Process.demonitor(ref, [:flush])
        next = Enum.reduce(job.apply, %{state | tracker_tasks: jobs}, fn apply_result, current -> apply_result.(current, result) end)
        {:handled, next}
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
        outcome =
          case Task.shutdown(job.task, :brutal_kill) do
            {:ok, value} -> value
            _ -> {:error, :tracker_task_timeout}
          end

        {:handled, state} = result(state, ref, outcome)
        state
    end
  end

  @spec stop(State.t()) :: :ok
  def stop(state) do
    Enum.each(state.tracker_tasks, fn {_ref, job} ->
      cancel_timer(job.timer)
      Task.shutdown(job.task, :brutal_kill)
    end)

    :ok
  end

  @spec cancel(State.t(), term()) :: State.t()
  def cancel(state, key) do
    Enum.reduce(state.tracker_tasks, state, fn {ref, job}, current ->
      if job.key == key do
        cancel_timer(job.timer)
        Task.shutdown(job.task, :brutal_kill)
        %{current | tracker_tasks: Map.delete(current.tracker_tasks, ref)}
      else
        current
      end
    end)
  end

  defp retain_completion(state, key, apply_result) do
    jobs =
      Map.new(state.tracker_tasks, fn {ref, job} ->
        if job.key == key, do: {ref, %{job | apply: Enum.uniq(job.apply ++ [apply_result])}}, else: {ref, job}
      end)

    %{state | tracker_tasks: jobs}
  end

  # A paginated poll has transport deadlines per request, not an arbitrary batch deadline.
  defp task_timer(:dispatch_poll, _ref), do: nil
  defp task_timer(_key, ref), do: Process.send_after(self(), {:tracker_task_timeout, ref}, @timeout_ms)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)
end
