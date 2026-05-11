defmodule SymphonyElixir.TUI.SnapshotSource do
  @moduledoc false

  alias SymphonyElixir.Orchestrator

  @spec snapshot() :: {:ok, map()} | :error
  def snapshot do
    case Orchestrator.snapshot(Orchestrator, 1_000) do
      %{} = snapshot ->
        {:ok,
         %{
           running: snapshot.running,
           retrying: snapshot.retrying,
           agent_totals: snapshot.agent_totals,
           rate_limits: snapshot.rate_limits,
           polling: Map.get(snapshot, :polling)
         }}

      _ ->
        :error
    end
  end
end
