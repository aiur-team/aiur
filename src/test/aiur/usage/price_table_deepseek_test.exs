defmodule Aiur.Usage.PriceTableDeepSeekTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.PriceTable

  alias Aiur.Usage.PriceTable

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
end
