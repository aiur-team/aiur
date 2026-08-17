defmodule Aiur.DecisionDispatchTasks.Worker do
  @moduledoc false

  require Logger

  def start(task_starter, operation) do
    case task_starter.(operation) do
      {:ok, %Task{} = task} -> {:ok, task}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_task_starter_result, other}}
    end
  rescue
    error -> {:error, {:task_start_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:task_start_failure, kind, reason}}
  end

  def start_supervised(operation) do
    {:ok, Task.Supervisor.async(Aiur.TaskSupervisor, operation)}
  end

  def notify(entry, result) do
    entry.callback.(entry.correlation, result)
    :ok
  rescue
    error ->
      Logger.error("decision dispatch terminal callback failed error=#{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.error("decision dispatch terminal callback failed kind=#{kind} reason=#{inspect(reason)}")
      :ok
  end

  def terminate(task) do
    Process.unlink(task.pid)
    Task.Supervisor.terminate_child(Aiur.TaskSupervisor, task.pid)
  end

  def schedule_timeout(_ref, :infinity), do: nil

  def schedule_timeout(ref, timeout) do
    Process.send_after(self(), {:decision_dispatch_timeout, ref}, timeout)
  end

  def cancel_timeout(nil, _ref), do: :ok

  def cancel_timeout(timer, ref) do
    case Process.cancel_timer(timer) do
      false -> flush_timeout(ref)
      _remaining -> :ok
    end
  end

  defp flush_timeout(ref) do
    receive do
      {:decision_dispatch_timeout, ^ref} -> :ok
    after
      0 -> :ok
    end
  end
end
