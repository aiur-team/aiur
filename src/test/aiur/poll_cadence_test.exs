defmodule Aiur.PollCadenceTest do
  use ExUnit.Case, async: false

  alias Aiur.PollCadence

  setup do
    PollCadence.forget_effective_interval_ms()
    on_exit(&PollCadence.forget_effective_interval_ms/0)
    :ok
  end

  describe "effective_interval_ms/1" do
    test "prefers an explicitly supplied interval over everything else" do
      :ok = PollCadence.publish_effective_interval_ms(120_000)

      assert PollCadence.effective_interval_ms(effective_interval_ms: 7_000) == 7_000
    end

    test "reads the interval the dispatcher published" do
      :ok = PollCadence.publish_effective_interval_ms(1_200_000)

      assert PollCadence.effective_interval_ms() == 1_200_000
    end

    test "a later publish replaces an earlier one" do
      :ok = PollCadence.publish_effective_interval_ms(5_000)
      :ok = PollCadence.publish_effective_interval_ms(1_200_000)

      assert PollCadence.effective_interval_ms() == 1_200_000
    end

    test "ignores a non-positive published value" do
      :ok = PollCadence.publish_effective_interval_ms(0)
      :ok = PollCadence.publish_effective_interval_ms(nil)

      assert PollCadence.effective_interval_ms(base_interval_ms: 30_000, webhook_widen_factor: 1.0, idle_widen_factor: 1.0) ==
               30_000
    end

    test "falls back to the widest cadence the configuration permits" do
      # 120s base, webhook-widened 2x, idle-widened 5x — the 1200s the operator
      # sees as `POLL idle backoff active: interval=1200s base=120s factor=5.0x`.
      assert PollCadence.effective_interval_ms(
               base_interval_ms: 120_000,
               webhook_widen_factor: 2.0,
               idle_widen_factor: 5.0
             ) == 1_200_000
    end
  end

  describe "widest_configured_interval_ms/1" do
    test "a factor at or below 1.0 never narrows the interval" do
      assert PollCadence.widest_configured_interval_ms(
               base_interval_ms: 5_000,
               webhook_widen_factor: 1.0,
               idle_widen_factor: 0.1
             ) == 5_000
    end
  end

  describe "stale_after_ms/2" do
    test "tracks the effective interval at every cadence" do
      for {interval_ms, expected_ms} <- [{5_000, 10_000}, {120_000, 240_000}, {1_200_000, 2_400_000}] do
        :ok = PollCadence.publish_effective_interval_ms(interval_ms)

        assert PollCadence.stale_after_ms(2) == expected_ms
      end
    end

    test "the floor only raises, never caps" do
      :ok = PollCadence.publish_effective_interval_ms(5_000)
      assert PollCadence.stale_after_ms(2, floor_ms: 120_000) == 120_000

      :ok = PollCadence.publish_effective_interval_ms(1_200_000)
      assert PollCadence.stale_after_ms(2, floor_ms: 120_000) == 2_400_000
    end
  end

  describe "stale_after_seconds/2" do
    test "rounds up so a sub-second threshold never becomes zero" do
      :ok = PollCadence.publish_effective_interval_ms(200)

      assert PollCadence.stale_after_seconds(2) == 1
    end

    test "derives whole seconds from the effective interval" do
      :ok = PollCadence.publish_effective_interval_ms(1_200_000)

      assert PollCadence.stale_after_seconds(2) == 2_400
    end
  end
end
