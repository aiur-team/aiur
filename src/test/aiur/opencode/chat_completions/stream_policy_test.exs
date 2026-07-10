defmodule Aiur.Opencode.ChatCompletions.StreamPolicyTest do
  use ExUnit.Case, async: true

  alias Aiur.Opencode.ChatCompletions.StreamPolicy

  describe "segment boundaries (segmented turn streams)" do
    test "a tool/command event past the threshold is a boundary" do
      assert StreamPolicy.segment_boundary?(:tool, 25_000, 20_000)
      assert StreamPolicy.segment_boundary?(:command, 20_000, 20_000)
    end

    test "below the threshold nothing is a boundary" do
      refute StreamPolicy.segment_boundary?(:tool, 19_999, 20_000)
    end

    test "assistant prose mid-thought is never a boundary" do
      refute StreamPolicy.segment_boundary?(:assistant, 120_000, 20_000)
      refute StreamPolicy.segment_boundary?(:reasoning, 120_000, 20_000)
    end

    test "idle boundary needs threshold age plus one heartbeat of silence" do
      assert StreamPolicy.idle_segment_boundary?(true, 3, 25_000, 16_000, 20_000, 15_000)
      refute StreamPolicy.idle_segment_boundary?(true, 3, 25_000, 5_000, 20_000, 15_000)
      refute StreamPolicy.idle_segment_boundary?(true, 3, 15_000, 16_000, 20_000, 15_000)
    end

    test "an empty continuation segment idle-closes after a longer silence (flush, bounded churn)" do
      # One heartbeat of silence is enough for a streamed segment, but an empty
      # continuation waits @empty_continuation_idle_factor (2) heartbeats so a
      # slow quiet tool run doesn't churn a marker every heartbeat.
      refute StreamPolicy.idle_segment_boundary?(false, 2, 120_000, 16_000, 20_000, 15_000)
      # After two heartbeats of silence it flushes queued operator input.
      assert StreamPolicy.idle_segment_boundary?(false, 2, 120_000, 31_000, 20_000, 15_000)
    end

    test "the empty turn-opening segment may idle-close (quiet turn start)" do
      assert StreamPolicy.idle_segment_boundary?(false, 0, 25_000, 16_000, 20_000, 15_000)
    end
  end

  describe "watchdog_action/2 (inactivity watchdog)" do
    test "closes once silence reaches the watchdog window" do
      assert {:close, 600_000} = StreamPolicy.watchdog_action(600_000, 600_000)
      assert {:close, 600_001} = StreamPolicy.watchdog_action(600_001, 600_000)
    end

    test "reschedules for the remaining window while activity is recent (no false close)" do
      # The timer fires 10 min after arming, but an actively-streaming turn
      # keeps bumping last_event_at — so measured silence is short and the
      # watchdog must reschedule for exactly the remaining window, never close.
      assert {:reschedule, 420_000} = StreamPolicy.watchdog_action(180_000, 600_000)
      assert {:reschedule, 600_000} = StreamPolicy.watchdog_action(0, 600_000)
    end

    test "the reschedule delay is always strictly positive (no zero/negative send_after)" do
      for silent <- [0, 1, 599_999] do
        assert {:reschedule, delay} = StreamPolicy.watchdog_action(silent, 600_000)
        assert delay > 0
      end
    end
  end

  describe "timing constants" do
    test "exposes the fixed timing constants as positive integers" do
      assert StreamPolicy.watchdog_ms() == 600_000
      assert StreamPolicy.heartbeat_ms() == 15_000
      assert StreamPolicy.empty_continuation_idle_factor() == 2
    end

    test "segment_threshold_ms defaults when unset and honors the app-env override" do
      prev = Application.get_env(:aiur, :turn_segment_threshold_ms)
      on_exit(fn -> restore_env(prev) end)

      Application.delete_env(:aiur, :turn_segment_threshold_ms)
      assert StreamPolicy.segment_threshold_ms() == 20_000

      Application.put_env(:aiur, :turn_segment_threshold_ms, 5_000)
      assert StreamPolicy.segment_threshold_ms() == 5_000
    end
  end

  defp restore_env(nil), do: Application.delete_env(:aiur, :turn_segment_threshold_ms)
  defp restore_env(value), do: Application.put_env(:aiur, :turn_segment_threshold_ms, value)
end
