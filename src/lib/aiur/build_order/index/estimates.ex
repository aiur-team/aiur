defmodule Aiur.BuildOrder.Index.Estimates do
  @moduledoc false
  alias Aiur.BuildOrder.{Estimates, SourceFreshness}

  @spec row(map(), term()) :: map()
  def row(%{sec: sec} = row, snapshot) when sec in ["plan", "now"] do
    overrides =
      case snapshot do
        {:ok, %{overrides: overrides}} -> overrides
        _ -> :unavailable
      end

    Map.merge(row, Estimates.resolve(row, overrides))
  end

  def row(row, _snapshot), do: row

  @spec source(term()) :: map()
  def source({:ok, %{health: health}}), do: SourceFreshness.source(health)
  def source({:error, health}), do: SourceFreshness.source(health)
  def source(_), do: %{state: "unavailable", observed_at: nil, reason: "estimates_unavailable"}

  @spec capacity(term()) :: map()
  def capacity({status, snapshot, metadata}) when status in [:current, :stale] and is_map(snapshot) and is_map(metadata) do
    max = get_in(snapshot, [:capacity, :max])
    %{max: if(is_integer(max) and max > 0, do: max), observed_at: SourceFreshness.ms(metadata[:observed_at]), stale: status == :stale}
  end

  def capacity(_), do: %{max: nil, observed_at: nil, stale: nil}
end
