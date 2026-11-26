defmodule Aiur.Orchestrator.State.ProcessLiveness do
  @moduledoc false

  @spec alive?(term()) :: boolean()
  def alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  def alive?(name) when is_atom(name), do: Process.whereis(name) != nil
  def alive?({:via, _, _} = name), do: registered_process_alive?(name)
  def alive?({:global, _} = name), do: registered_process_alive?(name)
  def alive?(_), do: false

  defp registered_process_alive?(name) do
    case GenServer.whereis(name) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end
end
