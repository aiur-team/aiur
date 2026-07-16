defmodule Aiur.Usage.Pricing do
  @moduledoc """
  Resolves one usage observation into exact, reproducible pricing slices.

  Provider-reported and API-equivalent estimates stay separate. Unknown or
  contradictory evidence is retained with explicit coverage instead of being
  converted to a guessed estimate or monetary zero.
  """

  alias Aiur.Usage.{PriceTable, Pricing.Components}
  alias Aiur.UsageEnvelope
  alias Aiur.UsageEnvelope.{ExactMoney, RelationshipRegistry}

  @version 1
  @subscription_disclosure %{
    marker: "*",
    copy_key: "usage.api_equivalent_estimate.subscription_disclosure"
  }

  @type result :: map()

  @spec resolve(UsageEnvelope.t(), RelationshipRegistry.catalog(), PriceTable.catalog(), keyword()) ::
          {:ok, result()} | {:error, atom()}
  def resolve(envelope, registry, price_table, options \\ [])

  def resolve(%UsageEnvelope{} = envelope, registry, price_table, options)
      when is_list(options) do
    currency = Keyword.get(options, :currency)
    {reconciliation, definition, relationship_reasons} = relationship_evidence(envelope, registry)

    {api_estimate, pricing_reasons} =
      api_estimate(envelope, reconciliation, definition, price_table, currency)

    reasons =
      envelope.coverage_reasons ++
        reconciliation.coverage_reasons ++ relationship_reasons ++ pricing_reasons

    {:ok,
     %{
       schema_version: @version,
       provider: envelope.provider,
       resolved_model: envelope.resolved_model,
       relationship_revision: envelope.relationship_revision,
       pricing_effective_date: envelope.pricing_effective_date,
       requested_currency: currency,
       price_table_revision: Map.get(price_table, :revision),
       account_generation: envelope.account_generation.generation,
       tier_join_key: tier_join_key(envelope),
       raw_tokens: envelope.tokens,
       token_reconciliation: reconciliation,
       token_coverage: reconciliation.coverage,
       provider_reported_estimate: provider_estimate(envelope.cost),
       api_equivalent_estimate: api_estimate,
       api_equivalent_coverage: coverage(api_estimate),
       api_equivalent_coverage_label: coverage(api_estimate) |> coverage_label(),
       subscription_estimate_disclosure: disclosure(envelope.auth_mode),
       coverage_reasons: Enum.uniq(reasons),
       coverage_reason_labels: reasons |> Enum.uniq() |> Enum.map(&reason_label/1)
     }}
  end

  def resolve(_envelope, _registry, _price_table, _options), do: {:error, :invalid_envelope}

  defp relationship_evidence(envelope, registry) do
    reconciliation = RelationshipRegistry.reconcile(registry, envelope)
    definition = RelationshipRegistry.resolve(registry, envelope)

    case {reconciliation, definition} do
      {{:ok, value}, {:ok, resolved}} -> {value, resolved, []}
      {{:ok, value}, {:error, reason}} -> {value, nil, [reason]}
      {{:error, reason}, _definition} -> {unknown_reconciliation(envelope, reason), nil, [reason]}
    end
  end

  defp unknown_reconciliation(envelope, reason) do
    %{
      canonical_total: nil,
      input_total: nil,
      output_total: nil,
      provider_total: envelope.tokens.provider_reported_total,
      derived_total: nil,
      relationship_revision: envelope.relationship_revision,
      status: :unreconciled,
      coverage: :unknown,
      coverage_reasons: [reason],
      discrepancy: nil
    }
  end

  defp api_estimate(envelope, reconciliation, definition, price_table, currency) do
    with :ok <- pricing_preconditions(envelope, reconciliation, definition),
         {:ok, components} <- Components.build(definition, envelope.tokens),
         {:ok, priced} <- price_components(components, envelope, price_table, currency) do
      {build_api_estimate(priced, price_table, currency, envelope.auth_mode), []}
    else
      {:error, reason} -> {nil, [reason]}
    end
  end

  defp pricing_preconditions(%{resolved_model: nil}, _reconciliation, _definition),
    do: {:error, :unknown_price_model}

  defp pricing_preconditions(%{pricing_effective_date: nil}, _reconciliation, _definition),
    do: {:error, :missing_pricing_effective_date}

  defp pricing_preconditions(%{auth_mode: :unknown}, _reconciliation, _definition),
    do: {:error, :unknown_auth_mode}

  defp pricing_preconditions(%{update_kind: :partial}, _reconciliation, _definition),
    do: {:error, :partial_update}

  defp pricing_preconditions(_envelope, %{coverage: coverage, coverage_reasons: reasons}, _definition)
       when coverage != :full,
       do: {:error, List.first(reasons) || :incomplete_token_reconciliation}

  defp pricing_preconditions(_envelope, _reconciliation, nil),
    do: {:error, :missing_historic_relationship_revision}

  defp pricing_preconditions(_envelope, _reconciliation, _definition), do: :ok

  defp price_components(components, envelope, price_table, currency) do
    Enum.reduce_while(components, {:ok, []}, fn component, {:ok, priced} ->
      query = %{
        provider: envelope.provider,
        resolved_model: envelope.resolved_model,
        token_dimension: component.token_dimension,
        relationship_revision: envelope.relationship_revision,
        currency: currency,
        pricing_effective_date: envelope.pricing_effective_date
      }

      case PriceTable.lookup(price_table, query) do
        {:ok, price} -> {:cont, {:ok, [priced_component(component, price) | priced]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, priced} -> {:ok, Enum.reverse(priced)}
      error -> error
    end)
  end

  defp priced_component(component, price) do
    amount =
      price.price
      |> Decimal.mult(Decimal.new(component.tokens))
      |> Decimal.div(Decimal.new(price.token_unit))

    component
    |> Map.merge(
      Map.take(price, [
        :provider,
        :resolved_model,
        :relationship_revision,
        :currency,
        :token_unit,
        :price_revision,
        :effective_date,
        :expires_before
      ])
    )
    |> Map.put(:price, price.price)
    |> Map.put(:amount, amount)
    |> Map.put(:amount_decimal, Decimal.to_string(amount, :normal))
    |> Map.put(:source_url, price.source_url)
    |> Map.put(:source_reviewed_at, price.source_reviewed_at)
    |> Map.put(:pricing_scope, price.pricing_scope)
  end

  defp build_api_estimate(components, price_table, currency, auth_mode) do
    amount = Enum.reduce(components, Decimal.new(0), &Decimal.add(&1.amount, &2))

    %{
      basis: :api_equivalent_estimate,
      basis_label: "API-equivalent estimate",
      amount: amount,
      amount_decimal: Decimal.to_string(amount, :normal),
      currency: currency,
      coverage: :full,
      coverage_label: coverage_label(:full),
      price_table_revision: price_table.revision,
      price_revisions: components |> Enum.map(& &1.price_revision) |> Enum.uniq() |> Enum.sort(),
      components: components,
      disclosure: disclosure(auth_mode)
    }
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

  defp coverage(nil), do: :unknown
  defp coverage(_estimate), do: :full

  defp coverage_label(:full), do: "Known"
  defp coverage_label(:partial), do: "Partial"
  defp coverage_label(:unknown), do: "Unknown"

  defp reason_label(reason) do
    reason |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end
end
