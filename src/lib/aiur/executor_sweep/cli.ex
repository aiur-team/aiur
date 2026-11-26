defmodule Aiur.ExecutorSweep.CLI do
  @moduledoc false

  import Aiur.ControlCLI.Protocol, only: [exit_marker: 1, guarded: 2]

  @doc "RPC entry point that reports partial checks and always emits the control exit marker."
  @spec rpc(keyword()) :: :ok
  def rpc(opts), do: guarded("executor-sweep", fn -> run(opts) |> exit_marker() end)

  @spec run(keyword()) :: 0
  def run(opts) do
    Aiur.ExecutorSweep.run(opts)
    0
  end
end
