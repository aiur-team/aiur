defmodule Aiur.Usage.PriceTableTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Aiur.Usage.PriceTable
  alias Aiur.Usage.PriceTable.Data

  @expected_rates [
    {:codex, "gpt-5.6-sol", "5.00", "0.50", "6.25", "30.00"},
    {:codex, "gpt-5.6-terra", "2.50", "0.25", "3.125", "15.00"},
    {:codex, "gpt-5.6-luna", "1.00", "0.10", "1.25", "6.00"},
    {:claude, "claude-opus-4-8", "5.00", "0.50", "6.25", "25.00"},
    {:claude, "claude-sonnet-4-6", "3.00", "0.30", "3.75", "15.00"},
    {:claude, "claude-haiku-4-5", "1.00", "0.10", "1.25", "5.00"}
  ]

  test "resolves every reviewed model dimension on its inclusive boundary" do
    assert {:ok, catalog} = PriceTable.default()
    assert length(catalog.entries) == 30

    for {provider, model, input, cached, creation, output} <- @expected_rates,
        {dimension, expected} <- [
          input: input,
          cached_input: cached,
          cache_creation_input: creation,
          output: output,
          reasoning_output: output
        ] do
      assert {:ok, price} = PriceTable.lookup(catalog, query(provider, model, dimension))
      assert Decimal.equal?(price.price, Decimal.new(expected))
      assert price.token_unit == 1_000_000
      assert price.effective_date == ~D[2026-07-15]
      assert price.expires_before == nil
      assert price.source_reviewed_at == ~D[2026-07-15]
      assert price.source_url == source_url(provider)
      assert price.price_revision == price_revision(provider)
    end

    assert catalog.revision == Data.catalog_revision()
  end

  test "selects old and new revisions solely from the occurrence date" do
    entries = [
      entry(%{price: "2.50", effective_date: ~D[2026-07-15], price_revision: "price-1"}),
      entry(%{price: "3.00", effective_date: ~D[2026-09-01], price_revision: "price-2"})
    ]

    assert {:ok, catalog} = PriceTable.new("table-1", entries)

    assert {:ok, old} = PriceTable.lookup(catalog, query(~D[2026-08-31]))
    assert Decimal.equal?(old.price, Decimal.new("2.50"))
    assert old.expires_before == ~D[2026-09-01]

    assert {:ok, new} = PriceTable.lookup(catalog, query(~D[2026-09-01]))
    assert Decimal.equal?(new.price, Decimal.new("3.00"))
    assert new.expires_before == nil
  end

  test "rejects ambiguous intervals, conflicting revisions, and inexact price input" do
    duplicate_date = [entry(), entry(%{price_revision: "price-2"})]

    assert {:error, :ambiguous_price_interval} =
             PriceTable.new("table-1", duplicate_date)

    reused_revision = [
      entry(),
      entry(%{effective_date: ~D[2026-08-01], price: "3.00"})
    ]

    assert {:error, :price_revision_conflict} =
             PriceTable.new("table-1", reused_revision)

    assert {:error, :float_not_allowed} =
             PriceTable.new("table-1", [entry(%{price: 2.5})])

    assert {:error, :invalid_price_currency} =
             PriceTable.new("table-1", [entry(%{currency: "usd"})])

    assert {:error, :invalid_price_token_unit} =
             PriceTable.new("table-1", [entry(%{token_unit: 0})])

    assert {:error, :invalid_price_source} =
             PriceTable.new("table-1", [entry(%{source_url: "http://example.com/pricing"})])
  end

  test "never crosses an exact pricing join dimension" do
    assert {:ok, catalog} = PriceTable.new("table-1", [entry()])

    assert {:error, :unknown_price_provider} =
             PriceTable.lookup(catalog, query(%{provider: :claude}))

    assert {:error, :unknown_price_model} =
             PriceTable.lookup(catalog, query(%{resolved_model: "gpt-other"}))

    assert {:error, :unsupported_price_currency} =
             PriceTable.lookup(catalog, query(%{currency: "EUR"}))

    assert {:error, :unknown_price_relationship_revision} =
             PriceTable.lookup(catalog, query(%{relationship_revision: "relationship-2"}))

    assert {:error, :unknown_price_dimension} =
             PriceTable.lookup(catalog, query(%{token_dimension: :output}))

    assert {:error, :price_not_yet_effective} =
             PriceTable.lookup(catalog, query(~D[2026-07-14]))
  end

  property "an ordered effective-date series has at most one deterministic winner" do
    check all(
            first_offset <- integer(0..30),
            gap <- integer(1..30),
            observation_offset <- integer(0..90),
            max_runs: 50
          ) do
      first_date = Date.add(~D[2026-01-01], first_offset)
      next_date = Date.add(first_date, gap)
      observed_date = Date.add(~D[2026-01-01], observation_offset)

      entries = [
        entry(%{effective_date: first_date, price_revision: "price-1"}),
        entry(%{effective_date: next_date, price_revision: "price-2", price: "3.00"})
      ]

      assert {:ok, catalog} = PriceTable.new("table-1", entries)

      case PriceTable.lookup(catalog, query(observed_date)) do
        {:ok, price} ->
          assert Date.compare(price.effective_date, observed_date) in [:lt, :eq]

          if price.expires_before do
            assert Date.compare(observed_date, price.expires_before) == :lt
          end

          assert PriceTable.lookup(catalog, query(observed_date)) == {:ok, price}

        {:error, :price_not_yet_effective} ->
          assert Date.compare(observed_date, first_date) == :lt
      end
    end
  end

  defp query(%Date{} = date), do: query(%{pricing_effective_date: date})

  defp query(overrides) when is_map(overrides) do
    Map.merge(
      %{
        provider: :codex,
        resolved_model: "gpt-5.6-terra",
        token_dimension: :input,
        relationship_revision: "codex-app-server-2026-07",
        currency: "USD",
        pricing_effective_date: ~D[2026-07-15]
      },
      overrides
    )
  end

  defp query(provider, model, dimension) do
    query(%{
      provider: provider,
      resolved_model: model,
      token_dimension: dimension,
      relationship_revision: relationship_revision(provider)
    })
  end

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        provider: :codex,
        resolved_model: "gpt-5.6-terra",
        token_dimension: :input,
        relationship_revision: "codex-app-server-2026-07",
        currency: "USD",
        price: "2.50",
        token_unit: 1_000_000,
        effective_date: ~D[2026-07-15],
        price_revision: "price-1",
        source_url: "https://developers.openai.com/api/docs/pricing",
        source_reviewed_at: ~D[2026-07-15],
        pricing_scope: "standard_global_direct_non_batch"
      },
      overrides
    )
  end

  defp relationship_revision(:codex), do: "codex-app-server-2026-07"
  defp relationship_revision(:claude), do: "claude-remote-control-2026-07"

  defp price_revision(:codex), do: "openai-standard-global-2026-07-15"
  defp price_revision(:claude), do: "anthropic-standard-global-2026-07-15"

  defp source_url(:codex), do: "https://developers.openai.com/api/docs/pricing"
  defp source_url(:claude), do: "https://platform.claude.com/docs/en/about-claude/pricing"
end
