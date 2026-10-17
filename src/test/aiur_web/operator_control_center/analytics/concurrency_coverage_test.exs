defmodule AiurWeb.OperatorControlCenter.Analytics.ConcurrencyCoverageTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.Analytics.ConcurrencyCoverage

  defp model(peak, occupied, util \\ 0), do: %{kpis: %{peak_conc: peak, mean_util_pct: util}, pressure: %{peak_occupied: occupied}}

  test "an unsampled fleet the daemon reports occupied reads unknown, never 0" do
    assert ConcurrencyCoverage.tile(model(0, 7), :session, "0 now / 10") ==
             %{val: "unknown", sub: "partial: 7 of 7 occupied slots not seen as active; 0 now / 10"}
  end

  test "a partly sampled fleet keeps the measured peak and names the gap" do
    assert ConcurrencyCoverage.tile(model(5, 7), :session, "5 now / 10") ==
             %{val: 5, sub: "partial: 2 of 7 occupied slots not seen as active; 5 now / 10"}
  end

  test "a fully sampled fleet, missing occupancy, or a Build Order scope keeps the plain tile" do
    assert ConcurrencyCoverage.tile(model(7, 7), :session, "7 now / 10") == %{val: 7, sub: "7 now / 10"}
    assert ConcurrencyCoverage.tile(model(0, nil), :session, "0 now / 10") == %{val: 0, sub: "0 now / 10"}
    assert ConcurrencyCoverage.tile(model(2, 7), %{kind: :build_order}, "of 10") == %{val: 2, sub: "of 10"}
  end

  # #4852: utilization is computed from the same unsampled agents, so its 0% is not a measurement.
  test "mean utilization of an unsampled fleet reads unknown with the concurrency reason, never 0%" do
    assert ConcurrencyCoverage.utilization(model(0, 7), :session, "of 8 cores") ==
             %{val: "unknown", sub: "partial: 7 of 7 occupied slots not seen as active"}

    assert ConcurrencyCoverage.unknown?(model(0, 7), :session)
  end

  test "mean utilization of a partly sampled fleet keeps the measured figure and names the gap" do
    assert ConcurrencyCoverage.utilization(model(5, 7, 12), :session, "of 8 cores") ==
             %{val: "12%", sub: "partial: 2 of 7 occupied slots not seen as active"}

    refute ConcurrencyCoverage.unknown?(model(5, 7), :session)
  end

  test "mean utilization of a fully sampled fleet or a Build Order scope keeps the plain tile" do
    assert ConcurrencyCoverage.utilization(model(7, 7, 30), :session, "of 8 cores") == %{val: "30%", sub: "of 8 cores"}
    assert ConcurrencyCoverage.utilization(model(0, 7), %{kind: :build_order}, "of 8 cores") == %{val: "0%", sub: "of 8 cores"}
    refute ConcurrencyCoverage.unknown?(model(0, 7), %{kind: :build_order})
    refute ConcurrencyCoverage.unknown?(model(0, nil), :session)
  end
end
