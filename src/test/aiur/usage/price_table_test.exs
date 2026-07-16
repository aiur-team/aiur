defmodule Aiur.Usage.PriceTableTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Aiur.Usage.PriceTable

  test "resolves reviewed prices on inclusive occurrence boundaries" do
    assert {:ok, catalog} = PriceTable.default()

    assert {:ok, price} =
             PriceTable.lookup(catalog, query(:codex, "gpt-5.6-terra", :cached_input))

    assert Decimal.equal?(price.price, Decimal.new("0.25"))
    assert price.token_unit == 1_000_000
    assert price.effective_date == ~D[2026-07-15]
    assert price.expires_before == nil
    assert price.price_revision == "openai-standard-global-2026-07-15"
    assert price.source_reviewed_at == ~D[2026-07-15]
    assert price.source_url == "https://developers.openai.com/api/docs/pricing"
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
end
