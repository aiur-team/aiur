defmodule Aiur.BuildOrder.GraphProjection.TaskLifecycle do
  @moduledoc false

  @spec start(map(), :catalog | {:selected, Aiur.TrackerIdentity.t()}, keyword()) :: {:ok, Task.t()} | :error
  def start(state, scope, reader_options) do
    owner = self()

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        receive do
          {:graph_projection_start, ^owner} -> read(state, scope, reader_options)
        end
      end)

    send(task.pid, {:graph_projection_start, owner})
    {:ok, task}
  catch
    :exit, _reason -> :error
    :error, _reason -> :error
  end

  @spec terminate(map(), Supervisor.supervisor()) :: :ok
  def terminate(%{timeout_ref: timeout_ref, pid: pid}, task_supervisor) do
    Process.cancel_timer(timeout_ref)
    terminate_child(task_supervisor, pid)
    :ok
  end

  defp read(%{catalog_reader: reader}, :catalog, options) when is_function(reader, 1), do: reader.(options)
  defp read(%{catalog_reader: reader}, :catalog, _options) when is_function(reader, 0), do: reader.()

  defp read(%{selected_reader: reader}, {:selected, identity}, options) when is_function(reader, 2),
    do: reader.(identity, options)

  defp read(%{selected_reader: reader}, {:selected, identity}, _options) when is_function(reader, 1),
    do: reader.(identity)

  defp terminate_child(task_supervisor, pid) do
    Task.Supervisor.terminate_child(task_supervisor, pid)
  catch
    :exit, _reason -> :ok
    :error, _reason -> :ok
  end
end
