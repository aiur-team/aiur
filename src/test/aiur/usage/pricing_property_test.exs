Code.require_file("pricing_fixture.exs", __DIR__)

defmodule Aiur.Usage.PricingPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Aiur.Usage.Pricing
  alias Aiur.Usage.PricingFixture, as: Fixture

  property "subset pricing preserves canonical counts and exact component sums" do
    check all(
            input <- non_negative_integer(),
            cached <- integer(0..input),
            creation <- integer(0..(input - cached)),
            output <- non_negative_integer(),
            reasoning <- integer(0..output),
            max_runs: 50
          ) do
      tokens = %{
        input: input,
        cached_input: cached,
        cache_creation_input: creation,
        output: output,
        reasoning_output: reasoning,
        provider_reported_total: input + output
      }

      envelope = Fixture.codex_envelope!(%{tokens: tokens})

      assert {:ok, result} =
               Pricing.resolve(
                 envelope,
                 Fixture.registry!(),
                 Fixture.default_price_table!(),
                 currency: "USD"
               )

      estimate = result.api_equivalent_estimate
      assert result.token_reconciliation.canonical_total == input + output
      assert Enum.sum(Enum.map(estimate.components, & &1.tokens)) == input + output

      component_sum =
        Enum.reduce(estimate.components, Decimal.new(0), fn component, sum ->
          Decimal.add(sum, component.amount)
        end)

      assert Decimal.equal?(estimate.amount, component_sum)
      assert estimate.currency == "USD"
      assert result.provider_reported_estimate.currency == "EUR"
    end
  end
end
