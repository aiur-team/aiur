defmodule Aiur.Usage.Pricing do
  @moduledoc """
  Resolves one usage observation into exact, reproducible pricing slices.

  Provider-reported and API-equivalent estimates stay separate. Unknown or
  contradictory evidence is retained with explicit coverage instead of being
  converted to a guessed estimate or monetary zero.
  """

  alias Aiur.Usage.{PriceTable, Pricing.Components, Pricing.Dimensions, Pricing.Result}
  alias Aiur.Usage.PriceTable.Window
  alias Aiur.UsageEnvelope
  alias Aiur.UsageEnvelope.RelationshipRegistry

  @type result :: map()

  @spec resolve(UsageEnvelope.t(), RelationshipRegistry.catalog(), PriceTable.catalog(), keyword()) ::
          {:ok, result()} | {:error, atom()}
  def resolve(envelope, registry, price_table, options \\ [])

  def resolve(%UsageEnvelope{} = envelope, registry, price_table, options)
      when is_list(options) do
    currency = Keyword.get(options, :currency)
    pricing_dimensions = Dimensions.from_options(envelope.provider, options)
    {reconciliation, definition, relationship_reasons} = relationship_evidence(envelope, registry)

    {api_estimate, pricing_reasons} =
      api_estimate(
        envelope,
        reconciliation,
        definition,
        price_table,
        currency,
        pricing_dimensions
      )

    reasons =
      envelope.coverage_reasons ++
        reconciliation.coverage_reasons ++ relationship_reasons ++ pricing_reasons

    {:ok,
     Result.build(
       envelope,
       price_table,
       currency,
       pricing_dimensions,
       reconciliation,
       api_estimate,
       reasons
     )}
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

  defp api_estimate(envelope, reconciliation, definition, price_table, currency, dimensions) do
    with :ok <- pricing_preconditions(envelope, reconciliation, definition, dimensions),
         {:ok, components} <- Components.build(definition, envelope.tokens),
         pricing <- price_components(components, envelope, price_table, currency, dimensions) do
      resolved_estimate(pricing, price_table, currency, envelope.auth_mode)
    else
      {:error, reason} -> {nil, [reason]}
    end
  end

  defp pricing_preconditions(%{resolved_model: nil}, _reconciliation, _definition, _dimensions),
    do: {:error, :unknown_price_model}

  defp pricing_preconditions(%{pricing_effective_date: nil}, _reconciliation, _definition, _dimensions),
    do: {:error, :missing_pricing_effective_date}

  defp pricing_preconditions(%{auth_mode: :unknown}, _reconciliation, _definition, _dimensions),
    do: {:error, :unknown_auth_mode}

  defp pricing_preconditions(%{update_kind: :partial}, _reconciliation, _definition, _dimensions),
    do: {:error, :partial_update}

  defp pricing_preconditions(
         _envelope,
         %{coverage: coverage, coverage_reasons: reasons},
         _definition,
         _dimensions
       )
       when coverage != :full,
       do: {:error, List.first(reasons) || :incomplete_token_reconciliation}

  defp pricing_preconditions(_envelope, _reconciliation, nil, _dimensions),
    do: {:error, :missing_historic_relationship_revision}

  defp pricing_preconditions(envelope, _reconciliation, _definition, dimensions),
    do: Dimensions.validate(envelope.provider, dimensions)

  defp price_components(components, envelope, price_table, currency, dimensions) do
    {priced, missing} =
      Enum.reduce(components, {[], []}, fn component, {priced, missing} ->
        query = price_query(component, envelope, currency, dimensions)

        case PriceTable.lookup(price_table, query) do
          {:ok, price} -> {[priced_component(component, price) | priced], missing}
          {:error, reason} -> {priced, [Map.put(component, :reason, reason) | missing]}
        end
      end)

    component_coverage(Enum.reverse(priced), Enum.reverse(missing))
  end

  defp price_query(component, envelope, currency, dimensions) do
    Map.merge(
      %{
        provider: envelope.provider,
        resolved_model: envelope.resolved_model,
        token_dimension: component.token_dimension,
        relationship_revision: envelope.relationship_revision,
        currency: currency,
        pricing_effective_date: envelope.pricing_effective_date,
        pricing_window: Window.resolve(envelope.provider, envelope.occurred_at)
      },
      Dimensions.for_component(envelope.provider, component.token_dimension, dimensions)
    )
  end

  defp component_coverage(priced, []), do: {:ok, priced}
  defp component_coverage([], missing), do: {:unknown, missing}
  defp component_coverage(priced, missing), do: {:partial, priced, missing}

  defp resolved_estimate({:ok, priced}, price_table, currency, auth_mode) do
    {Result.api_estimate(priced, price_table, currency, auth_mode), []}
  end

  defp resolved_estimate({:partial, priced, missing}, price_table, currency, auth_mode) do
    estimate = Result.partial_api_estimate(priced, missing, price_table, currency, auth_mode)
    {estimate, missing_reasons(missing)}
  end

  defp resolved_estimate({:unknown, missing}, _price_table, _currency, _auth_mode),
    do: {nil, missing_reasons(missing)}

  defp missing_reasons(missing), do: missing |> Enum.map(& &1.reason) |> Enum.uniq()

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
        :context_tier,
        :cache_write_duration,
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
end
