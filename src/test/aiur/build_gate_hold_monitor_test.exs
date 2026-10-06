defmodule Aiur.BuildGateHoldMonitorTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildGateHoldMonitor

  defp state(overrides) do
    struct(
      BuildGateHoldMonitor.State,
      Keyword.merge([threshold_seconds: 60, alerted: MapSet.new()], overrides)
    )
  end

  defp emitting_state(overrides \\ []) do
    state(Keyword.merge([emit_fun: fn topic, opts -> send(self(), {:emit, topic, opts}) end], overrides))
  end

  defp slot_holder(slot, command \\ "mix test", held \\ 120) do
    %{kind: :slot, slot: slot, command: command, held_for_seconds: held}
  end

  describe "evaluate/2" do
    test "alerts on a slot held at or beyond the threshold, naming the command" do
      s = emitting_state()
      status = %{enabled?: true, holders: [slot_holder(1)], timeouts: []}

      next = BuildGateHoldMonitor.evaluate(s, status)

      assert_received {:emit, "system.build_gate.hold_timeout.slot-1", opts}
      assert opts[:needs_attention] == true
      assert opts[:severity] == "warning"
      assert opts[:message] =~ "mix test"
      assert opts[:reason] =~ "slot 1"
      assert MapSet.member?(next.alerted, 1)
    end

    test "alerts on a holder self-release timeout marker even when the slot is already released" do
      s = emitting_state()

      status = %{
        enabled?: true,
        holders: [],
        timeouts: [%{slot: 1, command: "mix test --trace", held_for_seconds: 3_600, reason: "retained"}]
      }

      next = BuildGateHoldMonitor.evaluate(s, status)

      assert_received {:emit, "system.build_gate.hold_timeout.slot-1", opts}
      assert opts[:needs_attention] == true
      assert opts[:message] =~ "mix test --trace"
      assert MapSet.member?(next.alerted, 1)
    end

    test "does not re-alert an already-alerted slot while it stays offending" do
      s = emitting_state(alerted: MapSet.new([1]))
      status = %{enabled?: true, holders: [slot_holder(1)], timeouts: []}

      next = BuildGateHoldMonitor.evaluate(s, status)

      refute_received {:emit, _, _}
      assert MapSet.member?(next.alerted, 1)
    end

    test "resolves a slot whose offending condition cleared" do
      s = emitting_state(alerted: MapSet.new([1]))
      status = %{enabled?: true, holders: [], timeouts: []}

      next = BuildGateHoldMonitor.evaluate(s, status)

      assert_received {:emit, "system.build_gate.hold_timeout.slot-1.resolved", opts}
      assert opts[:needs_attention] == false
      assert opts[:severity] == "info"
      refute MapSet.member?(next.alerted, 1)
    end

    test "a held slot below the threshold never alerts" do
      s = emitting_state()
      status = %{enabled?: true, holders: [slot_holder(1, "mix test", 10)], timeouts: []}

      _next = BuildGateHoldMonitor.evaluate(s, status)

      refute_received {:emit, _, _}
    end

    test "a disabled gate resolves every latched slot without alerting" do
      s = emitting_state(alerted: MapSet.new([1]))

      _next = BuildGateHoldMonitor.evaluate(s, %{enabled?: false})

      assert_received {:emit, "system.build_gate.hold_timeout.slot-1.resolved", _opts}
    end

    test "a threshold of zero disables alerting entirely" do
      s = emitting_state(threshold_seconds: 0)
      status = %{enabled?: true, holders: [slot_holder(1, "mix test", 9_999)], timeouts: []}

      _next = BuildGateHoldMonitor.evaluate(s, status)

      refute_received {:emit, _, _}
    end

    test "marker records win over held records for the same slot" do
      s = emitting_state()

      status = %{
        enabled?: true,
        holders: [slot_holder(1, "held command", 120)],
        timeouts: [%{slot: 1, command: "marker command", held_for_seconds: 3_600, reason: "retained"}]
      }

      _next = BuildGateHoldMonitor.evaluate(s, status)

      assert_received {:emit, "system.build_gate.hold_timeout.slot-1", opts}
      assert opts[:message] =~ "marker command"
    end
  end

  describe "topic_for/1" do
    test "names the slot in a stable topic" do
      assert BuildGateHoldMonitor.topic_for(3) == "system.build_gate.hold_timeout.slot-3"
    end
  end
end
