defmodule Aiur.GitHub.BrokerTimeoutTest do
  @moduledoc """
  #2464: the budget-broker-timeout retry rate is a first-class signal — a
  queryable `system.github.budget_broker_retry` event per backoff, and exactly
  one dwelled `system.github.budget_broker_degraded` alert for a sustained rate.

  The monitor's own periodic timer is disabled for the test instance
  (`check_interval_ms: 0`); the dwell and window are driven with fake monotonic
  timestamps against the config defaults (window 300s < dwell 600s, threshold 5
  retries), so a burst that stops ages out of the window before the dwell
  completes and raises nothing.
  """

  use ExUnit.Case, async: false

  alias Aiur.GitHub.BrokerTimeout

  @name :broker_timeout_test
  @retry_topic "system.github.budget_broker_retry"
  @degraded_topic "system.github.budget_broker_degraded"
  @resolved_topic "system.github.budget_broker_degraded.resolved"

  setup do
    parent = self()

    emit_fun = fn topic, opts -> send(parent, {:emitted, topic, opts}) end

    start_supervised!({BrokerTimeout, name: @name, check_interval_ms: 0, emit_fun: emit_fun})
    :ok
  end

  defp record(now_ms, count) when is_integer(now_ms) and count >= 0 do
    Enum.each(1..count, fn _ -> BrokerTimeout.record(now_ms, name: @name) end)
  end

  defp check(now_ms), do: BrokerTimeout.check(now_ms, name: @name)
  defp count(now_ms), do: BrokerTimeout.count(now_ms, name: @name)

  test "a sustained broker-timeout rate raises exactly one degraded alert after the dwell" do
    # Degradation starts at t=1_001_000 and the rate is still elevated (≥ the
    # threshold retries in the trailing window) when the dwell completes at
    # t=1_601_000.
    record(1_000_000, 5)
    check(1_001_000)

    # The 600s dwell has not elapsed yet: nothing raised.
    refute_receive {:emitted, @degraded_topic, _}

    # Still degraded in the window, now past the dwell: exactly one alert.
    record(1_600_000, 5)
    check(1_601_000)

    assert_receive {:emitted, @degraded_topic, opts}
    assert opts[:needs_attention] == true
    assert opts[:severity] == "warning"
    assert opts[:reason] =~ "sustained"

    # Still degraded, still latched: exactly one, no re-emission.
    check(1_700_000)
    refute_receive {:emitted, @degraded_topic, _}

    # The rate ages out of the window: the .resolved sibling fires once.
    check(2_000_000)
    assert_receive {:emitted, @resolved_topic, resolved_opts}
    assert resolved_opts[:needs_attention] == false
  end

  test "a single isolated timeout raises nothing" do
    record(1_000, 1)

    # Even far past the dwell (1_000_000 ms in), one retry never crosses the
    # threshold, so the condition never exists and nothing pages.
    check(5_000)
    check(1_000_000)

    refute_receive {:emitted, @degraded_topic, _}
    refute_receive {:emitted, @resolved_topic, _}
  end

  test "a momentary burst that ages out before the dwell raises nothing" do
    record(1_000, 5)
    check(2_000)

    # Far past the dwell, but the burst aged out of the window first, so the
    # condition is gone and the dwell never completed on a live degradation.
    check(605_000)

    refute_receive {:emitted, @degraded_topic, _}
  end

  test "the retry count is queryable after the fact" do
    record(1_000, 3)
    record(2_000, 2)

    # The count is the raw retry total inside the window.
    assert count(5_000) == 5

    # And the raw telemetry event is emitted per retry — the persisted,
    # needs_attention-false record a future investigation can count (#2464
    # acceptance 3).
    Enum.each(1..5, fn _ ->
      assert_receive {:emitted, @retry_topic, opts}
      assert opts[:needs_attention] == false
    end)
  end

  test "a recovered-and-redegraded episode re-arms the alert latch" do
    # Episode one: degrade past the dwell, alert once, then recover.
    record(1_000_000, 5)
    check(1_001_000)
    record(1_600_000, 5)
    check(1_601_000)
    assert_receive {:emitted, @degraded_topic, _}

    check(2_000_000)
    assert_receive {:emitted, @resolved_topic, _}

    # Episode two: a fresh degradation alerts again — the latch re-arms rather
    # than staying latched forever.
    record(3_000_000, 5)
    check(3_001_000)
    record(3_600_000, 5)
    check(3_601_000)
    assert_receive {:emitted, @degraded_topic, _}

    check(4_000_000)
    assert_receive {:emitted, @resolved_topic, _}
  end
end
