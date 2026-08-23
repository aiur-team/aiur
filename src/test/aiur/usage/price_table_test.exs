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
  # Each row pins the exact effective-date revision it prices at, so a repriced
  # model (deepseek) appears once per revision. 2026-08-16 is DeepSeek's
  # peak/off-peak repricing date; a plain lookup prices the conservative peak
  # rate (off-peak time-of-day valuation is selected by `pricing_window`).
  @openai_compat_rates [
    {:kimi, "kimi-k2.7-code", ~D[2026-08-01], "0.95", "0.19", "4.00"},
    {:kimi, "kimi-k2.7-code-highspeed", ~D[2026-08-01], "0.95", "0.19", "4.00"},
    {:deepseek, "deepseek-v4-flash", ~D[2026-08-01], "0.14", "0.0028", "0.28"},
    {:deepseek, "deepseek-v4-flash", ~D[2026-08-16], "0.44", "0.014", "1.32"},
    {:deepseek, "deepseek-v4-pro", ~D[2026-08-16], "1.32", "0.044", "3.96"},
    {:deepseek, "deepseek-v4-flash-vision-exp", ~D[2026-08-16], "0.44", "0.014", "1.32"},
    {:openrouter, "deepseek/deepseek-v4-flash", ~D[2026-08-01], "0.14", "0.0028", "0.28"},
    {:openrouter, "deepseek/deepseek-v4-flash", ~D[2026-08-16], "0.06426", "0.012852", "0.12852"},
    {:openrouter, "moonshotai/kimi-k2.7-code", ~D[2026-08-01], "0.95", "0.19", "4.00"},
    {:openrouter, "anthropic/claude-sonnet-5", ~D[2026-08-01], "2.00", "0.20", "10.00"},
    {:openrouter, "anthropic/claude-opus-5", ~D[2026-08-01], "5.00", "0.50", "25.00"}
  ]
  test "resolves every reviewed model dimension on its inclusive boundary" do
    assert {:ok, catalog} = PriceTable.default()
    assert length(catalog.entries) == 111

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

    for {provider, model, effective_date, input, cached, output} <- @openai_compat_rates,
        {dimension, expected} <- [
          input: input,
          cached_input: cached,
          output: output,
          reasoning_output: output
        ] do
      assert {:ok, price} =
               PriceTable.lookup(
                 catalog,
                 query(provider, model, dimension, :not_applicable, :not_applicable)
                 |> Map.put(:pricing_effective_date, effective_date)
               )

      assert Decimal.equal?(price.price, Decimal.new(expected))
      assert price.effective_date == effective_date
      assert price.source_reviewed_at == effective_date
      assert price.context_tier == :not_applicable
      assert price.cache_write_duration == :not_applicable
    end

    assert catalog.revision == Data.catalog_revision()
  end

  test "DeepSeek repricing is effective-dated and never silently under-reports output" do
    assert {:ok, catalog} = PriceTable.default()

    # Spend before the 2026-08-16 repricing keeps the retained flat rate; the
    # next revision in the exact series is the exclusive bound.
    assert {:ok, old} =
             PriceTable.lookup(
               catalog,
               query(:deepseek, "deepseek-v4-flash", :output, :not_applicable, :not_applicable)
               |> Map.put(:pricing_effective_date, ~D[2026-08-15])
             )

    assert Decimal.equal?(old.price, Decimal.new("0.28"))
    assert old.expires_before == ~D[2026-08-16]
    assert old.price_revision == "deepseek-standard-global-2026-08-01"

    # From 2026-08-16 the published peak rate is priced. The retained $0.28
    # output rate under-reported peak spend by ~79% (1.32 vs 0.28), so the
    # corrected value must be the peak rate — never a silent low total.
    assert {:ok, peak} =
             PriceTable.lookup(
               catalog,
               query(:deepseek, "deepseek-v4-flash", :output, :not_applicable, :not_applicable)
               |> Map.put(:pricing_effective_date, ~D[2026-08-16])
             )

    assert Decimal.equal?(peak.price, Decimal.new("1.32"))
    assert peak.expires_before == nil
    assert peak.effective_date == ~D[2026-08-16]
    assert peak.source_reviewed_at == ~D[2026-08-16]
    assert peak.price_revision == "deepseek-standard-global-2026-08-16-peak"

    assert {:ok, input} =
             PriceTable.lookup(
               catalog,
               query(:deepseek, "deepseek-v4-flash", :input, :not_applicable, :not_applicable)
               |> Map.put(:pricing_effective_date, ~D[2026-08-16])
             )

    assert Decimal.equal?(input.price, Decimal.new("0.44"))

    assert {:ok, cached} =
             PriceTable.lookup(
               catalog,
               query(:deepseek, "deepseek-v4-flash", :cached_input, :not_applicable, :not_applicable)
               |> Map.put(:pricing_effective_date, ~D[2026-08-16])
             )

    assert Decimal.equal?(cached.price, Decimal.new("0.014"))
    assert cached.price_revision == "deepseek-standard-global-2026-08-16-peak"

    # OpenRouter's DeepSeek mirror is a flat third-party listing, effective
    # 2026-08-16, distinct from DeepSeek's first-party peak schedule.
    assert {:ok, mirror} =
             PriceTable.lookup(
               catalog,
               query(:openrouter, "deepseek/deepseek-v4-flash", :output, :not_applicable, :not_applicable)
               |> Map.put(:pricing_effective_date, ~D[2026-08-16])
             )

    assert Decimal.equal?(mirror.price, Decimal.new("0.12852"))
    assert mirror.expires_before == nil
    assert mirror.effective_date == ~D[2026-08-16]
    assert mirror.price_revision == "openrouter-standard-global-2026-08-16"
  end

  test "prices a deepseek call at the window actually in force" do
    assert {:ok, catalog} = PriceTable.default()

    # A weekday peak window (01:00-04:00 UTC) prices the peak revision.
    assert {:ok, peak} =
             PriceTable.lookup(
               catalog,
               deepseek_query("deepseek-v4-flash", :output, ~D[2026-08-16], :peak)
             )

    assert Decimal.equal?(peak.price, Decimal.new("1.32"))
    assert peak.window == :peak
    assert peak.price_revision == "deepseek-standard-global-2026-08-16-peak"

    # An off-peak window prices the off-peak revision (exactly 50% of peak).
    assert {:ok, off_peak} =
             PriceTable.lookup(
               catalog,
               deepseek_query("deepseek-v4-flash", :output, ~D[2026-08-16], :off_peak)
             )

    assert Decimal.equal?(off_peak.price, Decimal.new("0.66"))
    assert off_peak.window == :off_peak
    assert off_peak.price_revision == "deepseek-standard-global-2026-08-16-off_peak"

    assert {:ok, off_peak_input} =
             PriceTable.lookup(
               catalog,
               deepseek_query("deepseek-v4-flash", :input, ~D[2026-08-16], :off_peak)
             )

    assert Decimal.equal?(off_peak_input.price, Decimal.new("0.22"))

    assert {:ok, off_peak_cached} =
             PriceTable.lookup(
               catalog,
               deepseek_query("deepseek-v4-flash", :cached_input, ~D[2026-08-16], :off_peak)
             )

    assert Decimal.equal?(off_peak_cached.price, Decimal.new("0.007"))
  end

  test "all three current deepseek models are in the table, priced at peak and off-peak" do
    assert {:ok, catalog} = PriceTable.default()

    for {model, peak, off_peak} <- [
          {"deepseek-v4-flash", "1.32", "0.66"},
          {"deepseek-v4-pro", "3.96", "1.98"},
          {"deepseek-v4-flash-vision-exp", "1.32", "0.66"}
        ],
        window <- [:peak, :off_peak] do
      expected = if window == :peak, do: peak, else: off_peak

      assert {:ok, price} =
               PriceTable.lookup(
                 catalog,
                 deepseek_query(model, :output, ~D[2026-08-16], window)
               )

      assert Decimal.equal?(price.price, Decimal.new(expected))
      assert price.window == window
    end
  end

  test "an undeterminable window prices at the conservative peak rate" do
    assert {:ok, catalog} = PriceTable.default()

    # No `pricing_window` in the query — the aggregate path and any caller that
    # cannot resolve the occurrence window. The peak rate is the fallback, so
    # spend is never reported cheaper than it was.
    assert {:ok, price} =
             PriceTable.lookup(
               catalog,
               deepseek_query("deepseek-v4-flash", :output, ~D[2026-08-16], nil)
             )

    assert Decimal.equal?(price.price, Decimal.new("1.32"))
    assert price.window == :peak
  end

  test "flat revisions stay selectable before a windowed revision takes over" do
    assert {:ok, catalog} = PriceTable.default()

    # Before the 2026-08-16 repricing the flat rate applies regardless of the
    # requested window.
    for window <- [nil, :peak, :off_peak] do
      assert {:ok, price} =
               PriceTable.lookup(
                 catalog,
                 deepseek_query("deepseek-v4-flash", :output, ~D[2026-08-15], window)
               )

      assert Decimal.equal?(price.price, Decimal.new("0.28"))
      assert price.window == :flat
      assert price.expires_before == ~D[2026-08-16]
    end
  end

  test "a window-coverage gap is distinct from a price that is not yet effective" do
    entries = [
      entry(%{price: "2.00", effective_date: ~D[2026-08-16], price_revision: "price-peak", window: :peak})
    ]

    assert {:ok, catalog} = PriceTable.new("table-windowed", entries)

    # The :peak window prices fine on the effective date.
    assert {:ok, %{price: price}} =
             PriceTable.lookup(catalog, query(~D[2026-08-16]) |> Map.put(:pricing_window, :peak))

    assert Decimal.equal?(price, Decimal.new("2.00"))

    # Asking for :off_peak on the same date is a *coverage* gap — the price is
    # effective, just not for that window — not a "not yet effective".
    assert {:error, :price_window_uncovered} =
             PriceTable.lookup(catalog, query(~D[2026-08-16]) |> Map.put(:pricing_window, :off_peak))

    # A date before the first revision is genuinely not yet effective.
    assert {:error, :price_not_yet_effective} = PriceTable.lookup(catalog, query(~D[2026-08-15]))
  end

  test "peak and off-peak revisions on the same date are a valid interval, not ambiguous" do
    entries = [
      entry(%{price: "2.00", effective_date: ~D[2026-08-16], price_revision: "price-peak", window: :peak}),
      entry(%{price: "1.00", effective_date: ~D[2026-08-16], price_revision: "price-off", window: :off_peak})
    ]

    assert {:ok, catalog} = PriceTable.new("table-windowed", entries)

    assert {:ok, peak} =
             PriceTable.lookup(
               catalog,
               query(~D[2026-08-16]) |> Map.put(:pricing_window, :peak)
             )

    assert Decimal.equal?(peak.price, Decimal.new("2.00"))

    assert {:ok, off} =
             PriceTable.lookup(
               catalog,
               query(~D[2026-08-16]) |> Map.put(:pricing_window, :off_peak)
             )

    assert Decimal.equal?(off.price, Decimal.new("1.00"))
  end

  test "a duplicate revision within the same window is still rejected as ambiguous" do
    entries = [
      entry(%{price: "2.00", effective_date: ~D[2026-08-16], price_revision: "price-peak", window: :peak}),
      entry(%{price: "3.00", effective_date: ~D[2026-08-16], price_revision: "price-peak-2", window: :peak})
    ]

    assert {:error, :ambiguous_price_interval} = PriceTable.new("table-windowed", entries)
  end

  test "accepts the test-only registry provider without a validator clause" do
    fake =
      entry(%{
        provider: :fake,
        resolved_model: "fake-1",
        relationship_revision: "fake-app-server-1",
        context_tier: :not_applicable,
        cache_write_duration: :not_applicable
      })

    assert {:ok, catalog} = PriceTable.new("fake-registry-test", [fake])

    assert {:ok, %{provider: :fake}} =
             PriceTable.lookup(
               catalog,
               query(%{
                 provider: :fake,
                 resolved_model: "fake-1",
                 relationship_revision: "fake-app-server-1",
                 context_tier: :not_applicable,
                 cache_write_duration: :not_applicable
               })
             )
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

  defp deepseek_query(model, dimension, effective_date, pricing_window) do
    query(:deepseek, model, dimension, :not_applicable, :not_applicable)
    |> Map.put(:pricing_effective_date, effective_date)
    |> then(&if(is_nil(pricing_window), do: &1, else: Map.put(&1, :pricing_window, pricing_window)))
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
        window: :flat,
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
  defp relationship_revision(:kimi), do: "kimi-request-usage-2026-08"
  defp relationship_revision(:deepseek), do: "deepseek-request-usage-2026-08"
  defp relationship_revision(:openrouter), do: "openrouter-request-usage-2026-08"

  defp price_revision(:codex), do: "openai-standard-global-2026-07-15"
  defp price_revision(:claude), do: "anthropic-standard-global-2026-07-15"

  defp source_url(:codex), do: "https://developers.openai.com/api/docs/pricing"
  defp source_url(:claude), do: "https://platform.claude.com/docs/en/about-claude/pricing"
end
