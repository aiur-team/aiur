defmodule Aiur.Experiments.Auto.WindowRulesTest do
  use ExUnit.Case, async: true
  alias Aiur.Config.Schema.Experiments.Auto, as: Config
  alias Aiur.Experiments.Auto.WindowRules

  @start ~U[2026-01-01 00:00:00Z]

  defp at(day), do: DateTime.add(@start, day * 86_400)
  defp stamp(day), do: DateTime.to_iso8601(at(day))
  defp spec(stop \\ 14), do: %{"status" => "active", "design" => %{"kind" => "before_after"}, "windows" => %{"after" => %{"start" => stamp(0), "end" => stamp(stop)}}}

  test "minimum duration, sample guard and maximum window decide the report reason" do
    for {day, stop, met?, expected} <- [
          {9, 14, true, :noop},
          {14, 14, true, {:report_due, "guard_met", stamp(14)}},
          {14, 14, false, {:extend, stamp(21)}},
          {42, 42, false, {:report_due, "insufficient_data", stamp(42)}}
        ] do
      assert WindowRules.evaluate(spec(stop), met?, %Config{}, at(day)) == expected
    end
  end

  test "extensions clamp to the maximum and absent samples eventually end" do
    config = %Config{after_max_days: 30}

    for {stop, next} <- [{14, 21}, {21, 28}, {28, 30}] do
      assert WindowRules.evaluate(spec(stop), :unavailable, config, at(stop)) == {:extend, stamp(next)}
    end

    assert WindowRules.evaluate(spec(30), :unavailable, config, at(30)) == {:report_due, "insufficient_data", stamp(30)}
  end

  test "truncation ignores the minimum but preserves a met guard and closed windows" do
    assert WindowRules.truncate(spec(), false, at(8)) == {:report_due, "truncated", stamp(8)}
    assert WindowRules.truncate(spec(), true, at(8)) == {:report_due, "guard_met", stamp(8)}
    assert WindowRules.truncate(spec(), false, at(20)) == {:report_due, "truncated", stamp(14)}
    assert WindowRules.truncate(spec(), false, at(-1)) == :noop
  end

  test "future regression guard: terminal and cohort experiments are left alone" do
    assert WindowRules.evaluate(Map.put(spec(), "status", "report_due"), true, %Config{}, at(14)) == :noop
    assert WindowRules.evaluate(Map.put(spec(), "design", %{"kind" => "ab"}), true, %Config{}, at(14)) == :noop
  end

  test "every primary must meet the guard; unavailable and empty groups do not" do
    for samples <- [[], %{}, :unavailable, [%{guard_met?: true}, %{guard_met?: false}]] do
      assert WindowRules.evaluate(spec(), samples, %Config{}, at(14)) == {:extend, stamp(21)}
    end

    assert WindowRules.evaluate(spec(), %{"primary" => %{guard_met?: true}}, %Config{}, at(14)) == {:report_due, "guard_met", stamp(14)}
  end
end
