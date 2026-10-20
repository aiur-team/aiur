defmodule AiurWeb.OperatorControlCenter.Analytics.ConcurrencyCoverage do
  @moduledoc """
  Labels agent-derived figures — the peak-concurrency and mean-utilization tiles
  and the concurrency chart — partial or unknown when the active agent series
  sees fewer agents than the daemon's own occupied-slot peak, so an unsampled
  fleet never reads as an idle one. It also marks unattributed series windows
  unknown so they do not plot as zero.
  """

  @doc "The shared partial-coverage reason, or nil when the agent series is complete."
  @spec partial_reason(map(), term()) :: String.t() | nil
  # Occupancy is fleet-wide, so a Build Order scope legitimately samples fewer agents.
  def partial_reason(_model, %{kind: :build_order}), do: nil

  def partial_reason(%{kpis: %{peak_conc: peak}, pressure: %{peak_occupied: occupied}}, _scope)
      when is_number(occupied) and occupied > peak,
      do: "partial: #{occupied - peak} of #{occupied} occupied slots not seen as active"

  def partial_reason(_model, _scope), do: nil

  @doc "True when no agent was sampled at all, so agent-derived zeros are unknown rather than measured."
  @spec unknown?(map(), term()) :: boolean()
  def unknown?(%{kpis: %{peak_conc: peak}} = model, scope), do: peak == 0 and partial_reason(model, scope) != nil

  @spec tile(map(), term(), String.t()) :: %{val: term(), sub: String.t()}
  def tile(%{kpis: %{peak_conc: peak}} = model, scope, sub) do
    case partial_reason(model, scope) do
      nil ->
        %{val: peak, sub: sub}

      reason ->
        val = if unknown?(model, scope), do: "unknown", else: peak
        %{val: val, sub: "#{reason}; #{sub}"}
    end
  end

  @doc "True when no agent was sampled at all, so agent-derived zeros are unknown rather than measured."
  @spec utilization(map(), term(), String.t()) :: %{val: term(), sub: String.t()}
  def utilization(%{kpis: %{mean_util_pct: pct}} = model, scope, sub) do
    case partial_reason(model, scope) do
      nil -> %{val: "#{pct}%", sub: sub}
      reason -> %{val: if(unknown?(model, scope), do: "unknown", else: "#{pct}%"), sub: reason}
    end
  end

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
