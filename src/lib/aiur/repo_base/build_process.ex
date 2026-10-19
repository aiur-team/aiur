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
    terminate_processes(processes_for_build(worker_pid, build))
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
    processes = processes_for_build(worker_pid, build)

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
          ProcessTree.reap_process_group(group_id, ProcessTree.refresh_identity(os_pid, identity))
        else
          ProcessTree.reap_process_tree(os_pid, ProcessTree.refresh_identity(os_pid, identity))
        end

      if match?({:error, _reason}, result), do: Logger.warning("RepoBase build process cleanup failed: #{inspect(result)}")
    end)

    :ok
  end

  defp processes_for_build(worker_pid, build) do
    linked_processes = linked_port_processes(worker_pid)
    Map.merge(linked_processes, Map.get(build, :os_processes, %{}))
  end

  defp linked_port_processes(worker_pid) do
    case Process.info(worker_pid, :links) do
      {:links, links} ->
        Enum.reduce(links, %{}, &add_linked_process/2)

      _ ->
        %{}
    end
  end

  defp add_linked_process(link, processes) do
    case linked_port_process(link) do
      {os_pid, process} -> Map.put(processes, os_pid, process)
      nil -> processes
    end
  end

  defp linked_port_process(port) when is_port(port) do
    with {:os_pid, os_pid} <- Port.info(port, :os_pid),
         {:ok, identity} <- ProcessTree.process_identity(os_pid) do
      {os_pid, %{group_id: nil, identity: {:known, identity}}}
    else
      _ -> nil
    end
  end

  defp linked_port_process(_link), do: nil
end
