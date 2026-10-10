defmodule Aiur.ExecutorSessionCLI do
  @moduledoc "`aiur executor-session`: prints the live Executor's harness session handle."

  import Aiur.ControlCLI.Protocol, only: [exit_marker: 1, guarded: 2]

  alias Aiur.Executor.HarnessSession

  @doc "RPC entry point: runs the read under the control-protocol guard and emits the exit marker."
  @spec rpc(keyword()) :: :ok
  def rpc(opts), do: guarded("executor-session", fn -> opts |> run() |> exit_marker() end)

  @spec run(keyword()) :: 0
  def run(opts \\ []) do
    handle = HarnessSession.current(Keyword.take(opts, [:now, :path]))
    IO.puts(if Keyword.get(opts, :json, false), do: Jason.encode!(handle), else: render(handle))
    0
  end

  defp render(%{"state" => "live"} = handle), do: "live #{handle["harness"]} #{handle["session_id"]} pid=#{handle["harness_pid"] || "-"} cwd=#{handle["cwd"] || "-"}"
  defp render(%{"reason" => reason}), do: "unknown (#{reason})"
end
