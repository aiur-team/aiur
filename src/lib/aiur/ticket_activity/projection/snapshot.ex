defmodule Aiur.TicketActivity.Projection.Snapshot do
  @moduledoc false

  @spec entry(map() | nil, struct(), DateTime.t()) :: map() | :not_found
  def entry(nil, _state, _now), do: :not_found

  def entry(entry, state, now) do
    %{
      identity: entry.identity,
      status: freshness(entry.last_observed_at, state, now),
      active_stage: entry.stage && entry.stage.value,
      stage: stage_snapshot(entry.stage, state, now),
      progress: progress_snapshot(entry.progress, state, now),
      latest_evidence: evidence_snapshot(entry.latest_evidence),
      provenance: entry.provenance,
      observed_at: entry.last_observed_at,
      retention: entry.retention
    }
  end

  defp progress_snapshot(nil, _state, _now), do: %{status: :unknown}

  defp progress_snapshot(progress, state, now) do
    progress
    |> Map.drop([:order])
    |> Map.put(:status, :known)
    |> Map.put(:freshness, freshness(progress.observed_at, state, now))
  end

  defp stage_snapshot(nil, _state, _now), do: %{status: :unknown}

  defp stage_snapshot(stage, state, now) do
    stage
    |> Map.drop([:order])
    |> Map.put(:status, :known)
    |> Map.put(:freshness, freshness(stage.observed_at, state, now))
  end

  defp evidence_snapshot(nil), do: %{status: :unknown}

  defp evidence_snapshot(evidence) do
    evidence
    |> Map.drop([:order])
    |> Map.put(:status, :known)
  end

  defp freshness(observed_at, state, now) do
    if DateTime.diff(now, observed_at, :millisecond) > state.stale_after_ms,
      do: :stale,
      else: :fresh
  end
end
