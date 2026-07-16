defmodule Aiur.Usage.Pricing.Result do
  @moduledoc false

  alias Aiur.Usage.PriceTable
  alias Aiur.UsageEnvelope
  alias Aiur.UsageEnvelope.ExactMoney

  @version 1
  @subscription_disclosure %{
    marker: "*",
    copy_key: "usage.api_equivalent_estimate.subscription_disclosure"
  }

  @spec build(
          UsageEnvelope.t(),
          PriceTable.catalog(),
          String.t() | nil,
          map(),
          map(),
          map() | nil,
          [atom()]
        ) :: map()
  def build(envelope, price_table, currency, pricing_dimensions, reconciliation, api_estimate, reasons) do
    reasons = Enum.uniq(reasons)

    %{
      schema_version: @version,
      provider: envelope.provider,
      resolved_model: envelope.resolved_model,
      relationship_revision: envelope.relationship_revision,
      pricing_effective_date: envelope.pricing_effective_date,
      requested_currency: currency,
      pricing_context_tier: pricing_dimensions.context_tier,
      cache_write_duration: pricing_dimensions.cache_write_duration,
      price_table_revision: Map.get(price_table, :revision),
      account_generation: envelope.account_generation.generation,
      tier_join_key: tier_join_key(envelope),
      raw_tokens: envelope.tokens,
      token_reconciliation: reconciliation,
      token_coverage: reconciliation.coverage,
      provider_reported_estimate: provider_estimate(envelope.cost),
      api_equivalent_estimate: api_estimate,
      api_equivalent_coverage: coverage(api_estimate),
      api_equivalent_coverage_label: api_estimate |> coverage() |> coverage_label(),
      subscription_estimate_disclosure: disclosure(envelope.auth_mode),
      coverage_reasons: reasons,
      coverage_reason_labels: Enum.map(reasons, &reason_label/1)
    }
  end

  @spec api_estimate([map()], PriceTable.catalog(), String.t(), atom()) :: map()
  def api_estimate(components, price_table, currency, auth_mode) do
    amount = Enum.reduce(components, Decimal.new(0), &Decimal.add(&1.amount, &2))

    price_metadata(components, price_table, currency, auth_mode)
    |> Map.merge(%{
      amount: amount,
      amount_decimal: Decimal.to_string(amount, :normal),
      coverage: :full,
      coverage_label: coverage_label(:full),
      missing_components: []
    })
  end

  @spec partial_api_estimate([map()], [map()], PriceTable.catalog(), String.t(), atom()) :: map()
  def partial_api_estimate(components, missing, price_table, currency, auth_mode) do
    price_metadata(components, price_table, currency, auth_mode)
    |> Map.merge(%{
      amount: nil,
      amount_decimal: nil,
      coverage: :partial,
      coverage_label: coverage_label(:partial),
      missing_components: missing
    })
  end

  defp provider_estimate(nil), do: nil

  defp provider_estimate(%ExactMoney{} = money) do
    %{
      basis: :provider_reported_estimate,
      basis_label: "Provider-reported estimate",
      amount: money.amount,
      amount_decimal: Decimal.to_string(money.amount, :normal),
      currency: money.currency,
      coverage: money.coverage,
      coverage_label: coverage_label(money.coverage),
      coverage_reason: money.unknown_reason,
      source: money.source,
      source_version: money.source_version,
      measurement_kind: money.measurement_kind,
      counter_scope: money.counter_scope
    }
  end

  defp tier_join_key(%{account_generation: %{generation: generation}} = envelope)
       when is_binary(generation),
       do: {envelope.provider, envelope.backend, generation}

  defp tier_join_key(_envelope), do: nil

  defp disclosure(:chatgpt), do: @subscription_disclosure
  defp disclosure(_auth_mode), do: nil

  defp price_metadata(components, price_table, currency, auth_mode) do
    %{
      basis: :api_equivalent_estimate,
      basis_label: "API-equivalent estimate",
      currency: currency,
      price_table_revision: price_table.revision,
      price_revisions: components |> Enum.map(& &1.price_revision) |> Enum.uniq() |> Enum.sort(),
      components: components,
      disclosure: disclosure(auth_mode)
    }
  end

  defp coverage(nil), do: :unknown
  defp coverage(%{coverage: coverage}) when coverage in [:full, :partial], do: coverage

  defp coverage_label(:full), do: "Known"
  defp coverage_label(:partial), do: "Partial"
  defp coverage_label(:unknown), do: "Unknown"

  defp reason_label(reason) do
    reason |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end
end
