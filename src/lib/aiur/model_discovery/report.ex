defmodule Aiur.ModelDiscovery.Report do
  @moduledoc false

  # Log lines for one refresh: refusals, unpriced models and price drift.

  require Logger

  alias Aiur.ModelDiscovery.PriceDrift

  @spec report(Aiur.CodingAgent.backend(), [map()], [map()], keyword()) :: :ok
  def report(backend, models, refused, opts) do
    Logger.info(
      "model discovery (#{backend}): #{length(models)} models, #{length(refused)} refused" <>
        rejection_summary(refused)
    )

    report_unpriced(backend, models, opts)
    Enum.each(PriceDrift.price_drift(backend, Keyword.put(opts, :state, provisional_state(backend, models))), &warn_drift/1)
  end

  defp report_unpriced(backend, models, opts) do
    case PriceDrift.unpriced_models(backend, Keyword.put(opts, :state, provisional_state(backend, models))) do
      [] ->
        :ok

      unpriced ->
        Logger.warning(
          "model discovery (#{backend}): #{length(unpriced)} discovered models have no curated price row " <>
            "(#{preview(unpriced)}). They stay usable; their usage reports unknown cost, never zero."
        )
    end
  end

  defp warn_drift(drift) do
    Logger.warning(
      "model discovery price drift (#{drift.provider} #{drift.resolved_model} #{drift.token_dimension}): " <>
        "curated #{Decimal.to_string(drift.curated, :normal)} vs provider-quoted " <>
        "#{Decimal.to_string(drift.discovered, :normal)} per million tokens. The curated row is still in force — " <>
        "review it, aiur will not overwrite it."
    )
  end

  # Report against what was just fetched rather than re-reading the file, so the
  # numbers logged are the ones this refresh saw.
  defp provisional_state(backend, models) do
    %{"backends" => %{backend => %{"models" => models}}}
  end

  defp rejection_summary([]), do: ""

  defp rejection_summary(refused) do
    summary =
      refused
      |> Enum.frequencies_by(&Map.get(&1, "reason"))
      |> Enum.map_join(", ", fn {reason, count} -> "#{reason}: #{count}" end)

    " (#{summary})"
  end

  defp preview(ids), do: ids |> Enum.take(5) |> Enum.join(", ")
end
