defmodule Aiur.TestSupport.OrchestratorChild do
  @moduledoc false

  @doc "Returns the live supervised orchestrator pid, even if a test replaced its registered name."
  @spec supervised_pid() :: pid() | nil
  def supervised_pid do
    case Process.whereis(Aiur.Supervisor) do
      nil ->
        nil

      supervisor ->
        supervisor
        |> GenServer.call(:which_children, 5_000)
        |> Enum.find_value(fn
          {Aiur.Orchestrator, pid, _type, _modules} when is_pid(pid) -> pid
          _child -> nil
        end)
    end
  catch
    :exit, _reason -> nil
  end
end
