defmodule AiurWeb.OperatorControlCenter.MeterStylesTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.MeterStyles

  test "remaining tones share critical and warning boundaries" do
    assert MeterStyles.remaining_class(10) == "is-critical"
    assert MeterStyles.remaining_class(11) == "is-warning"
    assert MeterStyles.remaining_class(20) == "is-warning"
    assert MeterStyles.remaining_class(21) == ""
    assert MeterStyles.remaining_class(nil) == ""
  end

  test "run progress remains neutral before completion" do
    assert MeterStyles.meter_class(90) == ""
    assert MeterStyles.meter_class(99) == ""
    assert MeterStyles.meter_class(100) == "is-critical"
  end
end
