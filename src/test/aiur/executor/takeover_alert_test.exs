defmodule Aiur.Executor.TakeoverAlertTest do
  use ExUnit.Case, async: true

  alias Aiur.Executor.TakeoverAlert

  @t0 ~U[2026-01-01 00:00:00Z]

  defp hours(n), do: DateTime.add(@t0, round(n * 3600), :second)

  describe "age_hours/2" do
    test "is the whole elapsed hours between anchor and now" do
      assert TakeoverAlert.age_hours(@t0, hours(8)) == 8.0
      assert TakeoverAlert.age_hours(@t0, hours(0.5)) == 0.5
      assert TakeoverAlert.age_hours(hours(8), @t0) == 0.0
    end
  end

  describe "effective_anchor/2" do
    test "keeps the store anchor when there is no open PR" do
      assert TakeoverAlert.effective_anchor(@t0, nil) == @t0
    end

    test "uses the earlier of the store anchor and the open-PR creation floor" do
      pr_created = hours(-20)
      assert TakeoverAlert.effective_anchor(@t0, pr_created) == pr_created

      store_anchor = hours(-30)
      assert TakeoverAlert.effective_anchor(store_anchor, pr_created) == store_anchor
    end
  end

  describe "decide/4" do
    test "an ordinary ticket before the first threshold never alerts" do
      assert TakeoverAlert.decide(%{first_hours: 8, continuous_hours: 1}, 7.9, nil, @t0) == :wait
    end

    test "the first alert fires at the first threshold boundary (inclusive)" do
      assert TakeoverAlert.decide(%{first_hours: 8, continuous_hours: 1}, 8.0, nil, @t0) == :alert
    end

    test "the first alert is not repeated before the continuous cadence elapses" do
      last_alert = hours(8)
      assert TakeoverAlert.decide(%{first_hours: 8, continuous_hours: 1}, 8.5, last_alert, hours(8.5)) == :wait
    end

    test "the repeated alert fires once the continuous cadence elapses" do
      last_alert = hours(8)
      assert TakeoverAlert.decide(%{first_hours: 8, continuous_hours: 1}, 9.0, last_alert, hours(9)) == :alert
    end

    test "zero first-hours disables the alert entirely" do
      assert TakeoverAlert.decide(%{first_hours: 0, continuous_hours: 1}, 50.0, nil, @t0) == :disabled
      assert TakeoverAlert.decide(%{first_hours: 0, continuous_hours: 1}, 50.0, hours(1), hours(50)) == :disabled
    end

    test "zero continuous-hours keeps the first alert but disables repeats" do
      assert TakeoverAlert.decide(%{first_hours: 8, continuous_hours: 0}, 50.0, nil, @t0) == :alert
      assert TakeoverAlert.decide(%{first_hours: 8, continuous_hours: 0}, 50.0, hours(8), hours(50)) == :wait
    end

    test "negative thresholds raise a clear error" do
      assert_raise ArgumentError, ~r/executor_takeover_first_alert_hours/, fn ->
        TakeoverAlert.decide(%{first_hours: -1, continuous_hours: 1}, 1.0, nil, @t0)
      end

      assert_raise ArgumentError, ~r/executor_takeover_continuous_alert_hours/, fn ->
        TakeoverAlert.decide(%{first_hours: 8, continuous_hours: -1}, 1.0, nil, @t0)
      end
    end
  end

  describe "topic/1 and resolution_topic/1" do
    test "namespace takeover advisories per ticket" do
      assert TakeoverAlert.topic("101") == "system.executor_takeover.101"
      assert TakeoverAlert.resolution_topic("101") == "system.executor_takeover.101.resolved"
    end
  end

  describe "message/1" do
    test "renders age, owner, dispatch count and PR evidence" do
      evidence = %{
        identifier: "101",
        title: "Fix widget",
        url: nil,
        age_hours: 11.2,
        anchor: @t0,
        now: hours(11.2),
        first_hours: 8,
        continuous_hours: 1,
        repeated?: true,
        live_owner?: false,
        dispatches: 4,
        pr: %{
          number: 567,
          created_at: hours(-11.2),
          pushed_at: DateTime.add(hours(11.2), -7200, :second),
          mergeable_state: "clean",
          ci_state: nil
        }
      }

      message = TakeoverAlert.message(evidence)

      assert message =~ "#101 (Fix widget)"
      assert message =~ "still converging after 11.2h"
      assert message =~ "repeated reminder; cadence 1h"
      assert message =~ "PR #567 pushed 2.0h ago"
      assert message =~ "no live owning agent"
      assert message =~ "Dispatch/restart count: 4"
      assert message =~ "clean"
      assert message =~ "CI state: unavailable"
    end

    test "first alert message names the threshold and marks missing PR evidence" do
      evidence = %{
        identifier: "202",
        title: nil,
        url: nil,
        age_hours: 8.0,
        anchor: @t0,
        now: hours(8),
        first_hours: 8,
        continuous_hours: 1,
        repeated?: false,
        live_owner?: true,
        dispatches: 1,
        pr: nil
      }

      message = TakeoverAlert.message(evidence)

      assert message =~ "#202"
      assert message =~ "converging for 8.0h"
      assert message =~ "first alert; threshold 8h"
      assert message =~ "an agent is live on the ticket"
      assert message =~ "unavailable (no open PR observed)"
    end
  end
end
