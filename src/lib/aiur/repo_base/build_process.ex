defmodule Aiur.RepoBase.BuildProcess do
  @moduledoc false

  alias Aiur.ProcessTree
  require Logger

  @doc false
  @spec update_process(map(), atom(), pos_integer(), pos_integer() | nil, term()) :: map()
  def update_process(%{build: build} = state, :started, os_pid, group_id, identity) do
    processes = Map.put(build.os_processes, os_pid, %{group_id: group_id, identity: identity})
    %{state | build: %{build | os_pid: os_pid, os_processes: processes}}
  end

  def update_process(%{build: build} = state, :group, os_pid, group_id, identity) do
    process = %{group_id: group_id, identity: identity}
    %{state | build: %{build | os_processes: Map.put(build.os_processes, os_pid, process)}}
  end

  def update_process(%{build: build} = state, :finished, os_pid, _group_id, _identity) do
    %{state | build: %{build | os_processes: Map.delete(build.os_processes, os_pid)}}
  end

  @doc false
  @spec terminate(map()) :: :ok
  def terminate(%{build: %{pid: worker_pid} = build}) do
    terminate_processes(Map.get(build, :os_processes, %{}))
    if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)
    :ok
  end

  def terminate(_state), do: :ok

  @doc false
  @spec terminate_processes(map()) :: :ok
  def terminate_processes(processes), do: kill_processes(processes)

  @doc false
  @spec kill_async(map()) :: :ok
  def kill_async(%{pid: worker_pid} = build) do
    processes = Map.get(build, :os_processes, %{})

    spawn(fn ->
      kill_processes(processes)
      if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)
    end)

    :ok
  end

  defp kill_processes(processes) do
    Enum.each(processes, fn {os_pid, %{group_id: group_id, identity: identity}} ->
      group_id = group_id || ProcessTree.process_group_for_pid(os_pid)

      result =
        if is_integer(group_id) and group_id > 0 do
          ProcessTree.reap_process_group(group_id, current_identity(os_pid, identity))
        else
          ProcessTree.reap_process_tree(os_pid, current_identity(os_pid, identity))
        end

      if match?({:error, _reason}, result), do: Logger.warning("RepoBase build process cleanup failed: #{inspect(result)}")
    end)

    :ok
  end

  defp current_identity(os_pid, {:known, {:procfs_birth_and_session, start_time, _session}} = fallback) do
    case ProcessTree.process_identity(os_pid) do
      {:ok, {:procfs_birth_and_session, ^start_time, _session} = identity} -> {:known, identity}
      _ -> fallback
    end
  end

  defp current_identity(_os_pid, identity), do: identity
end
