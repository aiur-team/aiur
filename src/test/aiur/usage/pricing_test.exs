Code.require_file("pricing_fixture.exs", __DIR__)

defmodule Aiur.Usage.PricingTest do
  use ExUnit.Case, async: true

  alias Aiur.Usage.PriceTable
  alias Aiur.Usage.PriceTable.Data
  alias Aiur.Usage.Pricing
  alias Aiur.Usage.PricingFixture, as: Fixture

  test "prices Claude additive cache dimensions and output subsets exactly" do
    result = resolve(Fixture.claude_envelope!())

    assert result.token_reconciliation.canonical_total == 160
    assert result.token_reconciliation.input_total == 150
    assert result.token_reconciliation.output_total == 10
    assert result.api_equivalent_coverage == :full
    assert result.api_equivalent_estimate.basis == :api_equivalent_estimate
    assert result.api_equivalent_estimate.basis_label == "API-equivalent estimate"
    assert result.api_equivalent_estimate.currency == "USD"
    assert result.api_equivalent_estimate.amount_decimal == "0.0009475"
    assert Decimal.equal?(result.api_equivalent_estimate.amount, Decimal.new("0.0009475"))

    components = Map.new(result.api_equivalent_estimate.components, &{&1.token_dimension, &1})
    assert components.input.tokens == 100
    assert components.cached_input.tokens == 20
    assert components.cache_creation_input.tokens == 30
    assert components.output.tokens == 6
    assert components.reasoning_output.tokens == 4
    assert components.reasoning_output.parent_dimension == :output
    assert components.cached_input.provider == :claude
    assert components.cached_input.resolved_model == "claude-opus-4-8"
    assert components.cached_input.relationship_revision == "claude-remote-control-2026-07"
    assert components.cached_input.price_revision == "anthropic-standard-global-2026-07-15"
  end

  test "prices Codex subset children and only the parent remainder" do
    result = resolve(Fixture.codex_envelope!())

    assert result.token_reconciliation.canonical_total == 130
    assert result.api_equivalent_estimate.amount_decimal == "0.00061625"

    components = Map.new(result.api_equivalent_estimate.components, &{&1.token_dimension, &1})
    assert components.input.tokens == 50
    assert components.cached_input.tokens == 40
    assert components.cache_creation_input.tokens == 10
    assert components.output.tokens == 20
    assert components.reasoning_output.tokens == 10
    assert result.tier_join_key == {:codex, :app_server, "generation-a"}
  end

  test "preserves unlike provider and API estimates without combining them" do
    result = resolve(Fixture.codex_envelope!())

    assert result.provider_reported_estimate.basis == :provider_reported_estimate
    assert result.provider_reported_estimate.basis_label == "Provider-reported estimate"
    assert result.provider_reported_estimate.currency == "EUR"
    assert result.provider_reported_estimate.amount_decimal == "0.0012"
    assert result.api_equivalent_estimate.currency == "USD"
    refute Map.has_key?(result, :combined_estimate)
  end

  test "marks subscription API equivalents as estimates, never billed spend" do
    result = resolve(Fixture.codex_envelope!())

    assert result.api_equivalent_estimate.disclosure == %{
             marker: "*",
             copy_key: "usage.api_equivalent_estimate.subscription_disclosure"
           }

    labels = inspect(result)
    refute labels =~ "billed spend"
    refute labels =~ "actual spend"
  end

  test "keeps authoritative provider totals but rejects dimensional mismatch pricing" do
    registry = Fixture.registry!([Fixture.claude_definition()])
    mismatch = Fixture.claude_envelope!(%{tokens: claude_tokens(%{provider_reported_total: 161})})

    result = resolve(mismatch, registry)

    assert result.token_reconciliation.canonical_total == 161
    assert result.token_reconciliation.derived_total == 160
    assert result.token_reconciliation.discrepancy == 1
    assert result.api_equivalent_estimate == nil
    assert result.api_equivalent_coverage == :unknown
    assert :provider_total_discrepancy in result.coverage_reasons

    derived = Fixture.claude_envelope!(%{tokens: claude_tokens(%{provider_reported_total: nil})})
    derived_result = resolve(derived, registry)
    assert derived_result.token_reconciliation.canonical_total == 160
    assert derived_result.api_equivalent_estimate.amount_decimal == "0.0009475"
  end

  test "prices one valid mutually exclusive alternative and rejects contradictions" do
    relationship = "codex-alternatives-2026-07"

    definition =
      Fixture.codex_definition(%{
        revision: relationship,
        dimensions: %{
          input: {:mutually_exclusive, "prompt"},
          cached_input: {:mutually_exclusive, "prompt"},
          cache_creation_input: {:subset_of, :input},
          output: :additive,
          reasoning_output: {:subset_of, :output}
        }
      })

    registry = Fixture.registry!([definition])
    table = Fixture.price_table!(relationship)

    valid =
      Fixture.codex_envelope!(%{
        relationship_revision: relationship,
        tokens: codex_tokens(%{input: 100, cached_input: nil, cache_creation_input: 10})
      })

    assert resolve(valid, registry, table).api_equivalent_estimate.amount_decimal == "0.00013"

    contradiction =
      Fixture.codex_envelope!(%{
        relationship_revision: relationship,
        tokens: codex_tokens(%{input: 100, cached_input: 20, cache_creation_input: 10})
      })

    rejected = resolve(contradiction, registry, table)
    assert rejected.api_equivalent_estimate == nil
    assert rejected.raw_tokens == contradiction.tokens
    assert rejected.token_reconciliation.provider_total == 130
    assert :contradictory_relationship in rejected.coverage_reasons
  end

  test "retains raw evidence for unknown relationships and invalid catalogs" do
    unknown_definition =
      Fixture.codex_definition(%{
        dimensions: Map.put(Fixture.codex_definition().dimensions, :cached_input, :unknown)
      })

    envelope = Fixture.codex_envelope!()
    unknown = resolve(envelope, Fixture.registry!([unknown_definition]))

    assert unknown.api_equivalent_estimate == nil
    assert unknown.raw_tokens == envelope.tokens
    assert unknown.token_reconciliation.provider_total == 130
    assert :unknown_relationship in unknown.coverage_reasons

    invalid = resolve(envelope, %{version: 1, entries: :invalid})
    assert invalid.api_equivalent_estimate == nil
    assert invalid.raw_tokens == envelope.tokens
    assert :invalid_relationship_catalog in invalid.coverage_reasons
  end

  test "fails closed for unknown joins, partial evidence, and invalid arithmetic" do
    cases = [
      {Fixture.codex_envelope!(%{resolved_model: "gpt-unknown"}), "USD", :unknown_price_model},
      {Fixture.codex_envelope!(%{auth_mode: :unknown}), "USD", :unknown_auth_mode},
      {Fixture.codex_envelope!(), "EUR", :unsupported_price_currency},
      {Fixture.codex_envelope!(%{update_kind: :partial}), "USD", :partial_update},
      {
        Fixture.codex_envelope!(%{tokens: codex_tokens(%{cached_input: nil})}),
        "USD",
        :missing_dimension
      },
      {
        Fixture.codex_envelope!(%{tokens: codex_tokens(%{cached_input: 80, cache_creation_input: 30})}),
        "USD",
        :invalid_parent_remainder
      }
    ]

    for {envelope, currency, reason} <- cases do
      result = resolve(envelope, Fixture.registry!(), Fixture.default_price_table!(), currency)
      assert result.api_equivalent_estimate == nil
      assert result.api_equivalent_coverage == :unknown
      assert reason in result.coverage_reasons
    end

    missing_time =
      Fixture.codex_envelope!(%{
        occurred_at: nil,
        coverage_reasons: [:missing_trusted_occurrence_time]
      })

    result = resolve(missing_time)
    assert result.api_equivalent_estimate == nil
    assert :missing_pricing_effective_date in result.coverage_reasons
    refute result.coverage_reasons == []
  end

  test "requires an exact price for every billable component" do
    entries =
      Enum.reject(Data.entries(), fn entry ->
        entry.provider == :codex and entry.resolved_model == "gpt-5.6-terra" and
          entry.token_dimension == :output
      end)

    assert {:ok, sparse_table} = PriceTable.new("sparse-test-table", entries)

    result = resolve(Fixture.codex_envelope!(), Fixture.registry!(), sparse_table)
    assert result.api_equivalent_estimate == nil
    assert :unknown_price_dimension in result.coverage_reasons
  end

  test "never falls forward from a missing pinned relationship revision" do
    current =
      Fixture.codex_definition(%{
        revision: "codex-app-server-2026-08"
      })

    result = resolve(Fixture.codex_envelope!(), Fixture.registry!([current]))

    assert result.api_equivalent_estimate == nil
    assert result.token_reconciliation.provider_total == 130
    assert :missing_historic_relationship_revision in result.coverage_reasons
  end

  test "unknown account generations never produce a tier join" do
    envelope =
      Fixture.codex_envelope!(%{
        account_generation: Fixture.unknown_account_generation(),
        coverage_reasons: [:unknown_account_generation]
      })

    result = resolve(envelope)

    assert result.api_equivalent_estimate.amount_decimal == "0.00061625"
    assert result.tier_join_key == nil
    assert :unknown_account_generation in result.coverage_reasons
  end

  defp resolve(envelope),
    do: resolve(envelope, Fixture.registry!(), Fixture.default_price_table!(), "USD")

  defp resolve(envelope, registry),
    do: resolve(envelope, registry, Fixture.default_price_table!(), "USD")

  defp resolve(envelope, registry, table), do: resolve(envelope, registry, table, "USD")

  defp resolve(envelope, registry, table, currency) do
    assert {:ok, result} = Pricing.resolve(envelope, registry, table, currency: currency)
    result
  end

  defp codex_tokens(overrides) do
    Map.merge(
      %{
        input: 100,
        cached_input: 40,
        cache_creation_input: 10,
        output: 30,
        reasoning_output: 10,
        provider_reported_total: 130
      },
      overrides
    )
  end

  defp claude_tokens(overrides) do
    Map.merge(
      %{
        input: 100,
        cached_input: 20,
        cache_creation_input: 30,
        output: 10,
        reasoning_output: 4,
        provider_reported_total: 160
      },
      overrides
    )
  end
end
