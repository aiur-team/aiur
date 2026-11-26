defmodule Aiur.Protocol.ObservationAgeShortLabelTest do
  use ExUnit.Case, async: true

  alias Aiur.Protocol.ObservationAge
  alias AiurWeb.OperatorControlCenter.UnitsPresentation

  test "shared compact age labels preserve dashboard formatting and unknown values" do
    for {seconds, expected} <- [{0, "0s"}, {59, "59s"}, {60, "1m 0s"}, {3599, "59m 59s"}, {3600, "1h 0m"}, {7260, "2h 1m"}, {nil, "unknown age"}, {-1, "unknown age"}] do
      assert ObservationAge.short_label(seconds) == expected
      assert UnitsPresentation.age_label(seconds) == expected
    end
  end
end
