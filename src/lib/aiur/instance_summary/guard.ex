defmodule Aiur.InstanceSummary.Guard do
  @moduledoc false
  require Logger

  @keys ~w(contract version instance_id observed_at agents fleet commands executor build_orders background_agents capabilities status value reason age_ms freshness lower_bound active capacity globally_paused awaiting awaiting_blocking state consumers roots identity progress resolution truncated count)
  @strict Mix.env() == :test
  @budget 4_096

  @spec check!(map()) :: map()
  def check!(summary) do
    walk!(summary)
    bounded = if fits?(summary), do: summary, else: truncate_roots(summary)

    if fits?(bounded), do: bounded, else: over_budget(bounded)
  end

  if @strict do
    defp over_budget(_summary), do: raise(ArgumentError, "instance summary exceeds 4096 JSON bytes")
  else
    alias Aiur.InstanceSummary.Fact

    defp over_budget(summary) do
      Logger.warning("Instance summary exceeds 4096 JSON bytes; discarding field values")
      summary |> degrade() |> ensure_budget!()
    end

    defp degrade(%{status: _}), do: Fact.unknown("size_budget_exceeded")
    defp degrade(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, degrade(value)} end)
    defp degrade(value), do: value

    defp ensure_budget!(summary) do
      if fits?(summary), do: summary, else: raise(ArgumentError, "instance summary envelope exceeds 4096 JSON bytes")
    end
  end

  defp walk!(map) when is_map(map) do
    Enum.each(map, fn {key, value} ->
      unless (is_atom(key) or is_binary(key)) and to_string(key) in @keys do
        raise ArgumentError, "instance summary contains a forbidden key"
      end

      walk!(value)
    end)

    if Map.has_key?(map, :status) or Map.has_key?(map, "status"), do: validate_fact!(map)
  end

  defp walk!(list) when is_list(list), do: Enum.each(list, &walk!/1)
  defp walk!(_value), do: :ok

  defp validate_fact!(map) do
    status = Map.get(map, :status, Map.get(map, "status"))

    unless status in [:available, "available"] or not (Map.has_key?(map, :value) or Map.has_key?(map, "value")) do
      raise ArgumentError, "degraded instance summary fact carries a value"
    end
  end

  defp fits?(summary), do: byte_size(Jason.encode!(summary)) <= @budget

  defp truncate_roots(%{build_orders: %{status: :available, value: %{roots: roots} = value} = fact} = summary) when is_list(roots) do
    # Providers order roots by latest update; timestamps are deliberately not on the wire.
    put_in(summary.build_orders, %{fact | value: Map.merge(value, %{roots: Enum.take(roots, 3), truncated: true})})
  end

  defp truncate_roots(summary), do: summary
end
