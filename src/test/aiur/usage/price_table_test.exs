defmodule Aiur.Usage.PriceTableTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Aiur.Usage.PriceTable
  alias Aiur.Usage.PriceTable.Data

  @codex_rates [
    {"gpt-5.6-sol", :short_context, "5.00", "0.50", "6.25", "30.00"},
    {"gpt-5.6-sol", :long_context, "10.00", "1.00", "12.50", "45.00"},
    {"gpt-5.6-terra", :short_context, "2.50", "0.25", "3.125", "15.00"},
    {"gpt-5.6-terra", :long_context, "5.00", "0.50", "6.25", "22.50"},
    {"gpt-5.6-luna", :short_context, "1.00", "0.10", "1.25", "6.00"},
    {"gpt-5.6-luna", :long_context, "2.00", "0.20", "2.50", "9.00"}
  ]
  @claude_rates [
    {"claude-opus-4-8", "5.00", "0.50", "6.25", "10.00", "25.00"},
    {"claude-sonnet-4-6", "3.00", "0.30", "3.75", "6.00", "15.00"},
    {"claude-haiku-4-5", "1.00", "0.10", "1.25", "2.00", "5.00"}
  ]
  test "resolves every reviewed model dimension on its inclusive boundary" do
    assert {:ok, catalog} = PriceTable.default()
    assert length(catalog.entries) == 48

    for {model, context_tier, input, cached, creation, output} <- @codex_rates,
        {dimension, expected} <- [
          input: input,
          cached_input: cached,
          cache_creation_input: creation,
          output: output,
          reasoning_output: output
        ] do
      assert {:ok, price} =
               PriceTable.lookup(
                 catalog,
                 query(:codex, model, dimension, context_tier, :not_applicable)
               )

      assert Decimal.equal?(price.price, Decimal.new(expected))
      assert price.token_unit == 1_000_000
      assert price.effective_date == ~D[2026-07-15]
      assert price.expires_before == nil
      assert price.source_reviewed_at == ~D[2026-07-15]
      assert price.source_url == source_url(:codex)
      assert price.price_revision == price_revision(:codex)
      assert price.context_tier == context_tier
      assert price.cache_write_duration == :not_applicable
    end

    for {model, input, cached, five_minute_creation, one_hour_creation, output} <- @claude_rates,
        {dimension, duration, expected} <- [
          {:input, :not_applicable, input},
          {:cached_input, :not_applicable, cached},
          {:cache_creation_input, :five_minutes, five_minute_creation},
          {:cache_creation_input, :one_hour, one_hour_creation},
          {:output, :not_applicable, output},
          {:reasoning_output, :not_applicable, output}
        ] do
      assert {:ok, price} =
               PriceTable.lookup(
                 catalog,
                 query(:claude, model, dimension, :not_applicable, duration)
               )

      assert Decimal.equal?(price.price, Decimal.new(expected))
      assert price.context_tier == :not_applicable
      assert price.cache_write_duration == duration
      assert price.source_url == source_url(:claude)
      assert price.price_revision == price_revision(:claude)
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

    assert {:error, :invalid_price_context_tier} =
             PriceTable.new("table-1", [entry(%{context_tier: :not_applicable})])

    assert {:error, :invalid_cache_write_duration} =
             PriceTable.new("table-1", [
               entry(%{
                 provider: :claude,
                 context_tier: :not_applicable,
                 cache_write_duration: :five_minutes
               })
             ])

    assert {:error, :invalid_price_context_tier} =
             PriceTable.new("table-1", [
               entry(%{
                 provider: :claude,
                 context_tier: :short_context
               })
             ])
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

    assert {:error, :unknown_price_context_tier} =
             PriceTable.lookup(catalog, query(%{context_tier: :long_context}))

    assert {:error, :unknown_cache_write_duration} =
             PriceTable.lookup(catalog, query(%{cache_write_duration: :five_minutes}))

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
        context_tier: :short_context,
        cache_write_duration: :not_applicable,
        pricing_effective_date: ~D[2026-07-15]
      },
      overrides
    )
  end

  defp query(provider, model, dimension, context_tier, cache_write_duration) do
    query(%{
      provider: provider,
      resolved_model: model,
      token_dimension: dimension,
      relationship_revision: relationship_revision(provider),
      context_tier: context_tier,
      cache_write_duration: cache_write_duration
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
        context_tier: :short_context,
        cache_write_duration: :not_applicable,
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
