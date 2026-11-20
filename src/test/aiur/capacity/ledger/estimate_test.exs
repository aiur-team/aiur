defmodule Aiur.Capacity.Ledger.EstimateTest do
  use ExUnit.Case, async: true

  alias Aiur.Capacity.Ledger.Estimate

  test "window estimate prefers learned burn, then the default, else unknown" do
    assert Estimate.window_estimate(3.0, 5, 2) == {6.0, 3.0}
    assert Estimate.window_estimate(nil, 5, 2) == {10, 5}
    assert Estimate.window_estimate(nil, nil, 2) == {:unknown, :unknown}
  end

  test "usd estimate is the median per-turn cost, else the output-token bound, else unknown" do
    assert Estimate.usd_estimate([0.4, 0.1, 9.0], 2.0) == 0.4
    assert_in_delta Estimate.usd_estimate([0.2, 0.4], 2.0), 0.3, 1.0e-9
    assert Estimate.usd_estimate([], 2.0) == 2.0
    assert Estimate.usd_estimate([], nil) == :unknown
  end

  test "period spend reads API-equivalent USD and treats partial coverage as unknown" do
    usage = fn status, usd -> %{api_equivalent_estimate: %{rollup: %{"USD" => usd}, coverage: %{status: status}}} end

    assert Estimate.period_spend(usage.(:known, Decimal.new("1.25"))) == 1.25
    assert Estimate.period_spend(%{api_equivalent_estimate: %{rollup: %{}, coverage: %{status: :none}}}) == 0.0
    assert Estimate.period_spend(usage.(:partial, Decimal.new("1.25"))) == :unknown
    assert Estimate.period_spend(usage.(:unknown, nil)) == :unknown
    assert Estimate.period_spend(%{state: :unavailable}) == :unknown
  end
end
