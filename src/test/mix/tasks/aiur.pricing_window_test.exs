defmodule Mix.Tasks.Aiur.PricingWindowTest do
  use ExUnit.Case, async: true

  alias Aiur.Usage.PriceTable.Data
  alias Mix.Tasks.Aiur.PricingWindow

  @schedule Data.window_schedule(:deepseek)

  test "renders the current window and next boundary from a pinned clock" do
    # Monday 12:00 UTC is off-peak; the next flip is Tuesday 01:00 UTC.
    output = PricingWindow.render(@schedule, ~U[2026-08-24 12:00:00Z])

    assert output =~ "Current window: off_peak"
    assert output =~ "Next boundary: 2026-08-25T01:00:00Z -> peak"
  end

  test "renders a peak window and its next boundary" do
    output = PricingWindow.render(@schedule, ~U[2026-08-24 02:00:00Z])

    assert output =~ "Current window: peak"
    assert output =~ "Next boundary: 2026-08-24T04:00:00Z -> off_peak"
  end

  test "renders a weekend off-peak window" do
    output = PricingWindow.render(@schedule, ~U[2026-08-29 02:00:00Z])

    assert output =~ "Current window: off_peak"
    assert output =~ "Next boundary: 2026-08-31T01:00:00Z -> peak"
  end

  test "reports unknown when no provider declares a window" do
    assert PricingWindow.render(nil, ~U[2026-08-24 12:00:00Z]) =~
             "No provider currently declares a peak/off-peak window."
  end
end
