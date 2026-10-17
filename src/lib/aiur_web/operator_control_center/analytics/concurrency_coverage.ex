defmodule AiurWeb.OperatorControlCenter.Analytics.ConcurrencyCoverage do
  @moduledoc """
  Labels the peak-concurrency tile partial or unknown when the active agent
  series sees fewer agents than the daemon's own occupied-slot peak, and marks
  unattributed series windows unknown, so an unsampled fleet never reads as an
  idle one.
  """

  @spec tile(map(), term(), String.t()) :: %{val: term(), sub: String.t()}
  # Occupancy is fleet-wide, so a Build Order scope legitimately samples fewer agents.
  def tile(%{kpis: %{peak_conc: peak}}, %{kind: :build_order}, sub), do: %{val: peak, sub: sub}

  def tile(%{kpis: %{peak_conc: peak}, pressure: %{peak_occupied: occupied}}, _scope, _sub)
      when is_number(occupied) and occupied > peak do
    %{val: if(peak == 0, do: "unknown", else: peak), sub: "partial: #{occupied - peak} of #{occupied} occupied slots not seen as active"}
  end

  def tile(%{kpis: %{peak_conc: peak}}, _scope, sub), do: %{val: peak, sub: sub}

  @doc """
  Sets `conc` to nil for every bucket where the daemon reports occupied slots
  but no agent actor has a measured sample, such as adopted agents whose roots
  were never attributed: that window is unknown, not an idle 0. A
  ticket-filtered scope keeps its counts, because occupancy is fleet-wide.
  """
  @spec mark_unknown([map()], map(), keyword()) :: [map()]
  def mark_unknown(series, bucketed, opts) do
    if Keyword.has_key?(opts, :tickets), do: series, else: Enum.map(series, &mark_bucket(&1, bucketed))
  end

  defp mark_bucket(%{fleet_agents_occupied: occupied, idx: b} = bucket, bucketed) when is_number(occupied) and occupied > 0 do
    seen? = Enum.any?(bucketed, fn {_key, {kind, cells}} -> kind == :agent and Map.has_key?(cells, b) end)
    if seen?, do: bucket, else: %{bucket | conc: nil}
  end

  defp mark_bucket(bucket, _bucketed), do: bucket

  @doc "Splits a series into runs of buckets with a known `conc`, so a chart draws unknown windows as gaps."
  @spec known_runs([map()]) :: [[map()]]
  def known_runs(series) do
    series |> Enum.chunk_by(&is_nil(&1.conc)) |> Enum.reject(&is_nil(hd(&1).conc))
  end
end
