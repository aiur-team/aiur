defmodule AiurWeb.OperatorControlCenter.Analytics.WastedCapacityTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.Analytics.WastedCapacity

  test "sums each bucket against its observed cap, independent of the current cap" do
    buckets = [%{conc: 1, fleet_agents_effective: 13}, %{conc: 1, fleet_agents_effective: 8}]

    assert WastedCapacity.summarize(buckets, 0.1, true) == {1.9, false}
  end

  test "omits buckets without a cap and marks the total partial" do
    buckets = [%{conc: 1, fleet_agents_effective: 4}, %{conc: 1, fleet_agents_effective: nil}]

    assert WastedCapacity.summarize(buckets, 0.1, true) == {0.3, true}
    assert WastedCapacity.summarize([%{conc: 1, fleet_agents_effective: nil}], 0.1, true) == {nil, true}
    assert WastedCapacity.summarize([%{conc: 1, fleet_agents_effective: 4}], 0.1, false) == {0.3, true}
  end
end
