defmodule Aiur.Claude.ResetTimeTest do
  use ExUnit.Case, async: true

  alias Aiur.Claude.ResetTime

  test "parses the exact Khala banner clock across local midnight" do
    assert ResetTime.parse("12:20am (America/Los_Angeles)", ~U[2026-09-18 04:53:20Z]) ==
             "2026-09-18T07:20:00Z"

    assert ResetTime.parse("12:20am (America/Los_Angeles)", ~U[2026-09-18 08:00:00Z]) ==
             "2026-09-19T07:20:00Z"

    assert ResetTime.parse("12:20pm (America/Los_Angeles)", ~U[2026-09-18 04:53:20Z]) ==
             "2026-09-18T19:20:00Z"
  end

  test "uses the reset date's zone offset including DST gaps and overlaps" do
    assert ResetTime.parse("3:20am (America/Los_Angeles)", ~U[2026-03-08 08:00:00Z]) ==
             "2026-03-08T10:20:00Z"

    assert ResetTime.parse("2:20am (America/Los_Angeles)", ~U[2026-03-08 08:00:00Z]) ==
             "2026-03-08T10:00:00Z"

    assert ResetTime.parse("1:20am (America/Los_Angeles)", ~U[2026-11-01 08:30:00Z]) ==
             "2026-11-01T09:20:00Z"
  end

  test "keeps explicit timestamps and leaves invalid or zoneless clocks unknown" do
    assert ResetTime.parse("2026-09-18T00:20:00-07:00", ~U[2026-09-18 07:00:00Z]) ==
             "2026-09-18T07:20:00Z"

    for hint <- [nil, "12:20am", "12:20am (Unknown/Zone)", "13:20pm (Etc/UTC)", "12:99am (Etc/UTC)"] do
      assert ResetTime.parse(hint) == nil
    end
  end

  test "repeated expired explicit deadlines stay unknown across recovery polls" do
    deadline = ~U[2026-09-18 07:20:00Z]

    for seconds <- [1, 30, 60], hint <- ["2026-09-18T07:20:00Z", "2026-09-18T00:20:00-07:00"] do
      assert ResetTime.parse(hint, DateTime.add(deadline, seconds, :second)) == nil
    end
  end
end
