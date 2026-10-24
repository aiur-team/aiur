defmodule AiurWeb.OperatorControlCenter.Analytics.PressureSummaryTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.Analytics.Presenter

  test "keeps latest occupied count and effective cap in the same current sample" do
    series = [
      %{timestamp_ms: 1, fleet_capacity_status: "current", fleet_agents_occupied: 15, fleet_agents_latest_occupied: 15, fleet_agents_effective: 16},
      %{timestamp_ms: 2, fleet_capacity_status: "current", fleet_agents_occupied: 15, fleet_agents_latest_occupied: 15, fleet_agents_effective: 16}
    ]

    pressure = Presenter.pressure_summary(series)
    assert pressure.latest_occupied == 15
    assert pressure.latest_effective_capacity == 16

    unavailable = Enum.map(1..500, fn _ -> %{timestamp_ms: 4, fleet_capacity_status: "unavailable"} end)
    stale = Presenter.pressure_summary([List.first(series) | unavailable])
    assert stale.latest_occupied == nil
    assert stale.latest_effective_capacity == nil
  end

  test "uses the latest occupied count, not the bucket peak" do
    pressure =
      Presenter.pressure_summary([
        %{fleet_capacity_status: "current", fleet_agents_occupied: 17, fleet_agents_latest_occupied: 12, fleet_agents_effective: 16}
      ])

    assert pressure.peak_occupied == 17
    assert pressure.latest_occupied == 12
    assert pressure.latest_effective_capacity == 16
  end
end
