defmodule Aiur.BuildQueue.Measurement do
  @moduledoc "Reconcile demand before pacing, distinct from successful promotions."
  require Logger

  @spec record(map(), [map()]) :: :ok
  def record(state, projections) do
    previous = ready_ids(state.projections)
    ready = ready_ids(projections)
    newly_ready = MapSet.difference(ready, previous)

    row = %{
      captured_at_ms: state.clock.(),
      reconcile: state.reconciles + 1,
      freshness: state.freshness,
      phase: state.phase,
      ready: MapSet.size(ready),
      newly_ready: MapSet.size(newly_ready)
    }

    Logger.info("build_queue_reconcile #{Jason.encode!(row)}")
    :telemetry.execute([:aiur, :build_queue, :reconcile], Map.take(row, [:ready, :newly_ready]), Map.drop(row, [:ready, :newly_ready]))
    :ok
  end

  defp ready_ids(projections), do: projections |> Enum.filter(&(&1.state == :ready)) |> MapSet.new(& &1.issue_id)
end
