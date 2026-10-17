defmodule AiurWeb.OperatorControlCenter.Analytics.ConcurrencyCoverageTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.Analytics.ConcurrencyCoverage

  defp model(peak, occupied), do: %{kpis: %{peak_conc: peak}, pressure: %{peak_occupied: occupied}}

  test "an unsampled fleet the daemon reports occupied reads unknown, never 0" do
    assert ConcurrencyCoverage.tile(model(0, 7), :session, "0 now / 10") ==
             %{val: "unknown", sub: "partial: 7 of 7 occupied slots not seen as active"}
  end

  test "a partly sampled fleet keeps the measured peak and names the gap" do
    assert ConcurrencyCoverage.tile(model(5, 7), :session, "5 now / 10") ==
             %{val: 5, sub: "partial: 2 of 7 occupied slots not seen as active"}
  end

  test "a fully sampled fleet, missing occupancy, or a Build Order scope keeps the plain tile" do
    assert ConcurrencyCoverage.tile(model(7, 7), :session, "7 now / 10") == %{val: 7, sub: "7 now / 10"}
    assert ConcurrencyCoverage.tile(model(0, nil), :session, "0 now / 10") == %{val: 0, sub: "0 now / 10"}
    assert ConcurrencyCoverage.tile(model(2, 7), %{kind: :build_order}, "of 10") == %{val: 2, sub: "of 10"}
  end
end
