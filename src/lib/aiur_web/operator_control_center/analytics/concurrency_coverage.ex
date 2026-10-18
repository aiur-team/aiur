defmodule AiurWeb.OperatorControlCenter.Analytics.ConcurrencyCoverage do
  @moduledoc """
  Labels the peak-concurrency tile partial or unknown when the active agent
  series sees fewer agents than the daemon's own occupied-slot peak, so an
  unsampled fleet never reads as an idle one.
  """

  @spec tile(map(), term(), String.t()) :: %{val: term(), sub: String.t()}
  # Occupancy is fleet-wide, so a Build Order scope legitimately samples fewer agents.
  def tile(%{kpis: %{peak_conc: peak}}, %{kind: :build_order}, sub), do: %{val: peak, sub: sub}

  def tile(%{kpis: %{peak_conc: peak}, pressure: %{peak_occupied: occupied}}, _scope, sub)
      when is_number(occupied) and occupied > peak do
    %{val: if(peak == 0, do: "unknown", else: peak), sub: "partial: #{occupied - peak} of #{occupied} occupied slots not seen as active; #{sub}"}
  end

  def tile(%{kpis: %{peak_conc: peak}}, _scope, sub), do: %{val: peak, sub: sub}
end
