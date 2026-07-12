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

  describe "memory_gate/2" do
    test "holds below the configured floor and resumes at the boundary" do
      assert Orchestrator.memory_gate(2_047, 2_048) == :hold
      assert Orchestrator.memory_gate(2_048, 2_048) == :dispatch
      assert Orchestrator.memory_gate(4_096, 2_048) == :dispatch
    end

    test "is disabled without a positive floor" do
      assert Orchestrator.memory_gate(0, nil) == :dispatch
      assert Orchestrator.memory_gate(0, 0) == :dispatch
      assert Orchestrator.memory_gate(0, -1) == :dispatch
    end

    test "fails open when host memory is unavailable" do
      assert Orchestrator.memory_gate(:unavailable, 2_048) == :dispatch
    end
  end

  describe "read_memory/1" do
    setup do
      previous = Application.get_env(:aiur, :meminfo_source_override)
      on_exit(fn -> restore_app_env(:meminfo_source_override, previous) end)
      :ok
    end

    test "reads changing host memory while the gate is enabled" do
      Application.put_env(:aiur, :meminfo_source_override, fn ->
        {:ok, "MemAvailable: 1048576 kB\n"}
      end)

      assert Orchestrator.read_memory(2_048) == 1_024

      Application.put_env(:aiur, :meminfo_source_override, fn ->
        {:ok, "MemAvailable: 3145728 kB\n"}
      end)

      assert Orchestrator.read_memory(2_048) == 3_072
    end

    test "does not read the source while the gate is disabled" do
      Application.put_env(:aiur, :meminfo_source_override, fn ->
        flunk("MemAvailable must not be read when memory admission is disabled")
      end)

      assert Orchestrator.read_memory(nil) == :unavailable
      assert Orchestrator.read_memory(0) == :unavailable
    end
  end

  describe "fd_gate/1" do
    test "holds below the ten-percent reserve and resumes at the boundary" do
      assert Orchestrator.fd_gate(%{used: 91, limit: 100, available: 9, headroom_ratio: 0.09}) == :hold
      assert Orchestrator.fd_gate(%{used: 90, limit: 100, available: 10, headroom_ratio: 0.10}) == :dispatch
      assert Orchestrator.fd_gate(%{used: 50, limit: 100, available: 50, headroom_ratio: 0.50}) == :dispatch
    end

    test "rounds the integer reserve up without floating-point ambiguity" do
      assert Orchestrator.fd_headroom_threshold(%{limit: 256}) == 26
      assert Orchestrator.fd_gate(%{used: 231, limit: 256, available: 25, headroom_ratio: 25 / 256}) == :hold
      assert Orchestrator.fd_gate(%{used: 230, limit: 256, available: 26, headroom_ratio: 26 / 256}) == :dispatch
    end

    test "fails open when unavailable and closed when sampling is exhausted" do
      assert Orchestrator.fd_gate(:unavailable) == :dispatch
      assert Orchestrator.fd_gate(:exhausted) == :hold
    end
  end

  describe "load_envelope/4" do
    test "increases effective capacity below the per-scheduler target" do
      assert {3, nil} = Orchestrator.load_envelope(1, nil, 6.0, envelope_options(ramp_step: 2, now_ms: 1_000))
      assert {5, nil} = Orchestrator.load_envelope(3, nil, 12.0, envelope_options(ramp_step: 2, now_ms: 2_000))
    end

    test "restores the static cap under clear CPU headroom when work is queued" do
      options = envelope_options(cpu_headroom: %{idle_percent: 75.0, runnable: 3}, queued_work?: true)

      assert {10, 1_000} = Orchestrator.load_envelope(3, 1_000, 10.0, options)
    end

    test "keeps additive recovery without demand, clear idle headroom, or low runnable pressure" do
      assert {4, nil} =
               Orchestrator.load_envelope(
                 3,
                 nil,
                 10.0,
                 envelope_options(cpu_headroom: %{idle_percent: 75.0, runnable: 3})
               )

      assert {4, nil} =
               Orchestrator.load_envelope(
                 3,
                 nil,
                 10.0,
                 envelope_options(cpu_headroom: %{idle_percent: 59.9, runnable: 3}, queued_work?: true)
               )

      assert {4, nil} =
               Orchestrator.load_envelope(
                 3,
                 nil,
                 10.0,
                 envelope_options(cpu_headroom: %{idle_percent: 75.0, runnable: 12}, queued_work?: true)
               )

      assert {4, nil} = Orchestrator.load_envelope(3, nil, 10.0, envelope_options(queued_work?: true))
    end

    test "never increases beyond the static/session concurrency cap" do
      assert {10, nil} = Orchestrator.load_envelope(9, nil, 1.0, envelope_options(ramp_step: 3, now_ms: 1_000))
    end

    test "decreases multiplicatively above target and honors the cooldown" do
      assert {3, 1_000} = Orchestrator.load_envelope(5, nil, 13.0, envelope_options(now_ms: 1_000))

      assert {3, 1_000} =
               Orchestrator.load_envelope(3, 1_000, 13.0, envelope_options(now_ms: 2_000))

      assert {2, 61_000} =
               Orchestrator.load_envelope(3, 1_000, 13.0, envelope_options(now_ms: 61_000))

      assert {1, 121_000} =
               Orchestrator.load_envelope(2, 61_000, 13.0, envelope_options(now_ms: 121_000))
    end

    test "preserves capacity when load is unavailable and disables cleanly with a nil target" do
      assert {3, 1_000} =
               Orchestrator.load_envelope(3, 1_000, :unavailable, envelope_options(now_ms: 2_000))

      assert {10, nil} = Orchestrator.load_envelope(3, 1_000, 99.0, envelope_options(target: nil, now_ms: 2_000))
    end

    test "holds at minimum of 1 when already floored under high load, keeping prior decrease timestamp" do
      # When effective is already 1 and load is still high, reduced == effective
      # so the decrease timestamp is not advanced (nothing actually changed).
      assert {1, nil} = Orchestrator.load_envelope(1, nil, 13.0, envelope_options(now_ms: 5_000))
    end

    test "starts from static limit when effective is nil on the first dispatch cycle" do
      # nil effective (no prior envelope reading) normalises to the static cap
      # before evaluating whether to ramp or decrease.
      assert {10, nil} = Orchestrator.load_envelope(nil, nil, 1.0, envelope_options(now_ms: 1_000))
    end
  end

  defp envelope_options(overrides) do
    Map.merge(
      %{
        target: 1.0,
        schedulers: 12,
        static_limit: 10,
        ramp_step: 1,
        cooldown_ms: 60_000,
        now_ms: 0,
        cpu_headroom: :unavailable,
        queued_work?: false
      },
      Map.new(overrides)
    )
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, value), do: Application.put_env(:aiur, key, value)
end
