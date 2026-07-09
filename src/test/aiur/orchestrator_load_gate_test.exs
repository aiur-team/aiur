defmodule Aiur.OrchestratorLoadGateTest do
  use ExUnit.Case, async: false

  alias Aiur.Orchestrator

  # The load gate holds NEW dispatch when the 1-min load average exceeds
  # threshold * schedulers, so concurrently-running agents' mix-test suites do
  # not melt the box (#465). It must never touch already-running agents and must
  # fail open whenever it is disabled or load is unreadable.
  describe "load_gate/3" do
    test "holds new dispatch when 1-min load exceeds threshold * schedulers" do
      # 12 cores, threshold 1.5 => the per-core ceiling is 18.
      assert Orchestrator.load_gate(20.0, 1.5, 12) == :hold
    end

    test "dispatches while load is below the per-core ceiling" do
      assert Orchestrator.load_gate(10.0, 1.5, 12) == :dispatch
    end

    test "dispatches at the exact ceiling (only strictly-greater holds)" do
      assert Orchestrator.load_gate(18.0, 1.5, 12) == :dispatch
    end

    test "is disabled when the threshold is nil" do
      assert Orchestrator.load_gate(99.0, nil, 12) == :dispatch
    end

    test "is disabled when the threshold is zero or negative" do
      assert Orchestrator.load_gate(99.0, 0.0, 12) == :dispatch
      assert Orchestrator.load_gate(99.0, -1.0, 12) == :dispatch
    end

    test "fails open when the load average is unavailable (non-Linux host)" do
      assert Orchestrator.load_gate(:unavailable, 1.5, 12) == :dispatch
    end
  end

  # read_load/1 is the wiring that decides WHETHER to read /proc at all: an
  # explicit-disable nil threshold must never touch the load source, while an
  # enabled threshold reads the live 1-min average. This guards the short-circuit
  # operators can use when they intentionally disable the gate.
  describe "read_load/1" do
    setup do
      previous = Application.get_env(:aiur, :loadavg_source_override)
      on_exit(fn -> restore_app_env(:loadavg_source_override, previous) end)
      :ok
    end

    test "reads the live load when the gate is enabled" do
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "7.5 1 1 1/1 1"} end)
      assert Orchestrator.read_load(1.5) == 7.5
    end

    test "reads the live load for an enabled envelope even when the hard gate is disabled" do
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "7.5 1 1 1/1 1"} end)
      assert Orchestrator.read_load(nil, 1.0) == 7.5
    end

    test "does NOT read the load source when the threshold is nil (explicitly disabled)" do
      Application.put_env(:aiur, :loadavg_source_override, fn ->
        flunk("avg1 must not be read when the load gate is disabled")
      end)

      assert Orchestrator.read_load(nil) == :unavailable
    end

    test "does NOT read the load source when the threshold is zero" do
      Application.put_env(:aiur, :loadavg_source_override, fn ->
        flunk("avg1 must not be read when the threshold disables the gate")
      end)

      assert Orchestrator.read_load(0.0) == :unavailable
    end
  end

  describe "load_envelope/9" do
    test "increases effective capacity below the per-scheduler target" do
      assert {3, nil} = Orchestrator.load_envelope(1, nil, 6.0, 1.0, 12, 10, 2, 60_000, 1_000)
      assert {5, nil} = Orchestrator.load_envelope(3, nil, 12.0, 1.0, 12, 10, 2, 60_000, 2_000)
    end

    test "never increases beyond the static/session concurrency cap" do
      assert {10, nil} = Orchestrator.load_envelope(9, nil, 1.0, 1.0, 12, 10, 3, 60_000, 1_000)
    end

    test "decreases multiplicatively above target and honors the cooldown" do
      assert {3, 1_000} = Orchestrator.load_envelope(5, nil, 13.0, 1.0, 12, 10, 1, 60_000, 1_000)

      assert {3, 1_000} =
               Orchestrator.load_envelope(3, 1_000, 13.0, 1.0, 12, 10, 1, 60_000, 2_000)

      assert {2, 61_000} =
               Orchestrator.load_envelope(3, 1_000, 13.0, 1.0, 12, 10, 1, 60_000, 61_000)

      assert {1, 121_000} =
               Orchestrator.load_envelope(2, 61_000, 13.0, 1.0, 12, 10, 1, 60_000, 121_000)
    end

    test "preserves capacity when load is unavailable and disables cleanly with a nil target" do
      assert {3, 1_000} =
               Orchestrator.load_envelope(3, 1_000, :unavailable, 1.0, 12, 10, 1, 60_000, 2_000)

      assert {10, nil} = Orchestrator.load_envelope(3, 1_000, 99.0, nil, 12, 10, 1, 60_000, 2_000)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, value), do: Application.put_env(:aiur, key, value)
end
