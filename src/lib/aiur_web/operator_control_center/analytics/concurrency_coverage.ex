defmodule AiurWeb.OperatorControlCenter.Analytics.ConcurrencyCoverage do
  @moduledoc """
  Labels agent-derived figures — the peak-concurrency and mean-utilization tiles
  and the concurrency chart — partial or unknown when the active agent series
  sees fewer agents than the daemon's own occupied-slot peak, so an unsampled
  fleet never reads as an idle one.
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

  @spec utilization(map(), term(), String.t()) :: %{val: term(), sub: String.t()}
  def utilization(%{kpis: %{mean_util_pct: pct}} = model, scope, sub), do: label(model, scope, "#{pct}%", sub)

  defp label(model, scope, val, sub) do
    case partial_reason(model, scope) do
      nil -> %{val: val, sub: sub}
      reason -> %{val: if(unknown?(model, scope), do: "unknown", else: val), sub: reason}
    end
  end
end
