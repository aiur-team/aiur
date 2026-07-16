defmodule Aiur.Usage.Pricing do
  @moduledoc """
  Resolves one usage observation into exact, reproducible pricing slices.

  Provider-reported and API-equivalent estimates stay separate. Unknown or
  contradictory evidence is retained with explicit coverage instead of being
  converted to a guessed estimate or monetary zero.
  """

  alias Aiur.Usage.{PriceTable, Pricing.Components, Pricing.Result}
  alias Aiur.UsageEnvelope
  alias Aiur.UsageEnvelope.RelationshipRegistry

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

    {:ok, Result.build(envelope, price_table, currency, reconciliation, api_estimate, reasons)}
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
      {Result.api_estimate(priced, price_table, currency, envelope.auth_mode), []}
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
end
