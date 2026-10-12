defmodule Aiur.Orchestrator.DispatchPolicy.GatesTest do
  use Aiur.TestSupport

  alias Aiur.{ModelAvailability, Workflow}
  alias Aiur.Orchestrator.DispatchPolicy

  describe "load_gate/3" do
    test "matches the load gate truth table" do
      assert DispatchPolicy.load_gate(20.0, 1.5, 12) == :hold
      assert DispatchPolicy.load_gate(10.0, 1.5, 12) == :dispatch
      assert DispatchPolicy.load_gate(18.0, 1.5, 12) == :dispatch
      assert DispatchPolicy.load_gate(99.0, nil, 12) == :dispatch
      assert DispatchPolicy.load_gate(99.0, 0.0, 12) == :dispatch
      assert DispatchPolicy.load_gate(99.0, -1.0, 12) == :dispatch
      assert DispatchPolicy.load_gate(:unavailable, 1.5, 12) == :dispatch
    end
  end

  describe "load_admission_reason/4" do
    @contention %{idle_percent: 5.0, nice_percent: 0.0, reclaimable_percent: 5.0, runnable: 20}
    @clear_headroom %{idle_percent: 10.0, nice_percent: 70.0, reclaimable_percent: 80.0, runnable: 74}

    test "returns the exact binding details used by admission_gate" do
      assert {:hold, %{signal: :load, measured: 25.0, threshold: 24.0}} =
               DispatchPolicy.load_admission_reason(25.0, 1.5, 16, @contention)

      assert DispatchPolicy.load_admission_reason(24.0, 1.5, 16, @contention) == :dispatch
    end

    test "requires real CPU contention before a high load average holds dispatch" do
      assert DispatchPolicy.load_admission_reason(143.0, 1.5, 16, @clear_headroom) == :dispatch

      assert {:hold,
              %{
                signal: :load,
                measured: 143.0,
                threshold: 24.0,
                reclaimable_cpu_percent: 5.0,
                reclaimable_cpu_threshold: 60.0
              }} = DispatchPolicy.load_admission_reason(143.0, 1.5, 16, @contention)
    end

    # #2089: `SystemCpu.headroom/2` needs two `/proc/stat` reads, so the first
    # admission decision after the orchestrator boots — the ramp-from-zero
    # decision — has no window and yields `:unavailable`. Holding on that put
    # back the uncorroborated load-average false positive #1610 removed: on a
    # host whose load average is inflated by niced builds or I/O wait, new work
    # was withheld with no CPU evidence at all. An unmeasured corroboration is
    # not a measurement of contention, so it must dispatch. Every hold therefore
    # carries a measured `reclaimable_cpu_percent`.
    test "an unmeasured CPU window cannot hold, however high the load average" do
      for load <- [24.1, 143.0, 10_000.0] do
        assert DispatchPolicy.load_admission_reason(load, 1.5, 16, :unavailable) == :dispatch
        assert DispatchPolicy.run_queue_admission_reason(9_999, 16, 1.5, :unavailable) == :dispatch
      end

      # The corroboration is what releases the hold, not the absence of the gate:
      # the same load with a measured low-headroom window still holds.
      assert {:hold, %{signal: :load, reclaimable_cpu_percent: 5.0}} =
               DispatchPolicy.load_admission_reason(143.0, 1.5, 16, @contention)

      assert {:hold, %{signal: :run_queue, reclaimable_cpu_percent: 5.0}} =
               DispatchPolicy.run_queue_admission_reason(9_999, 16, 1.5, @contention)
    end

    # admission_gate/1 must never report a load decision that
    # load_admission_reason/4 would not make, and the reported threshold must
    # always be the already multiplied `threshold * schedulers` — the operator
    # reads that number straight off the status line, so the two surfaces cannot
    # be allowed to print different values for the same gate (#1610).
    test "admission_gate never disagrees with load_admission_reason" do
      probes = fn load, cpu_headroom ->
        %{
          memory_mb: :unavailable,
          memory_threshold_mb: nil,
          fd_sample: :unavailable,
          runnable: :unavailable,
          run_queue_threshold: nil,
          schedulers: 16,
          load: load,
          load_threshold: 1.5,
          build_status: %{enabled?: false, capacity: 0, active: 0, queued: 0},
          provider_backends: [],
          github_quota: :available,
          cpu_snapshot: :unavailable,
          cpu_headroom: cpu_headroom,
          target: nil,
          queued_demand?: true
        }
      end

      for load <- [0.0, 1.0, 23.9, 24.0, 24.1, 25.0, 400.0, :unavailable],
          cpu_headroom <- [@contention, @clear_headroom, :unavailable] do
        assert DispatchPolicy.admission_gate(probes.(load, cpu_headroom)) ==
                 DispatchPolicy.load_admission_reason(load, 1.5, 16, cpu_headroom)
      end

      assert {:hold, %{signal: :load, threshold: 24.0}} =
               DispatchPolicy.admission_gate(probes.(25.0, @contention))
    end
  end

  describe "prewarm_gate/2" do
    test "matches the prewarm gate truth table" do
      assert DispatchPolicy.prewarm_gate(false, :building) == :dispatch
      assert DispatchPolicy.prewarm_gate(false, :idle) == :dispatch
      assert DispatchPolicy.prewarm_gate(false, {:error, :boom}) == :dispatch
      assert DispatchPolicy.prewarm_gate(true, :ready) == :dispatch
      assert DispatchPolicy.prewarm_gate(true, {:error, :base_build_failed}) == :dispatch
      assert DispatchPolicy.prewarm_gate(true, :building) == :hold
    end
  end

  describe "read_load/1" do
    test "returns unavailable when the threshold is disabled" do
      assert DispatchPolicy.read_load(nil) == :unavailable
      assert DispatchPolicy.read_load(0) == :unavailable
      assert DispatchPolicy.read_load(-1) == :unavailable
    end
  end

  describe "read_cpu/1" do
    test "does not touch procfs when the adaptive envelope is disabled" do
      Application.put_env(:aiur, :proc_stat_source_override, fn ->
        flunk("/proc/stat must not be read when the envelope is disabled")
      end)

      on_exit(fn -> Application.delete_env(:aiur, :proc_stat_source_override) end)

      assert DispatchPolicy.read_cpu(nil) == :unavailable
      assert DispatchPolicy.read_cpu(0) == :unavailable
    end

    test "reads the CPU snapshot when the run-queue gate is enabled even with the envelope disabled" do
      Application.put_env(:aiur, :proc_stat_source_override, fn ->
        {:ok, "cpu 100 0 100 800 0 0 0 0 0 0\nprocs_running 3\n"}
      end)

      on_exit(fn -> Application.delete_env(:aiur, :proc_stat_source_override) end)

      assert %{runnable: 3} = DispatchPolicy.read_cpu(nil, 1.5)
      assert DispatchPolicy.read_cpu(nil, nil) == :unavailable
      assert DispatchPolicy.read_cpu(nil, 0) == :unavailable
    end

    test "reads the CPU snapshot when any CPU-corroborated gate is enabled" do
      Application.put_env(:aiur, :proc_stat_source_override, fn ->
        {:ok, "cpu 100 0 100 800 0 0 0 0 0 0\nprocs_running 3\n"}
      end)

      on_exit(fn -> Application.delete_env(:aiur, :proc_stat_source_override) end)

      assert %{runnable: 3} = DispatchPolicy.read_cpu(1.0, nil, 0.0)
      assert %{runnable: 3} = DispatchPolicy.read_cpu(nil, nil, 1.5)
      assert DispatchPolicy.read_cpu(nil, 0.0, 0.0) == :unavailable
    end
  end

  describe "provider_gate/1" do
    test "holds only when every dispatchable backend is usage-limited" do
      write_workflow_file!(Workflow.workflow_file_path())
      future = ~U[2099-01-01 00:00:00Z]
      :ok = ModelAvailability.mark_limited("codex", DateTime.to_iso8601(future))

      assert DispatchPolicy.provider_gate(["codex"]) == :hold
      assert DispatchPolicy.provider_gate([]) == :dispatch
      assert DispatchPolicy.provider_gate(:unavailable) == :dispatch
    end

    test "dispatches when any dispatchable backend remains available" do
      write_workflow_file!(Workflow.workflow_file_path())
      future = ~U[2099-01-01 00:00:00Z]
      :ok = ModelAvailability.mark_limited("codex", DateTime.to_iso8601(future))

      assert DispatchPolicy.provider_gate(["codex", "claude"]) == :dispatch
    end

    test "refreshes a stale Codex limit through the gate and resumes dispatch" do
      path = Aiur.TestSupport.tmp_root!("aiur-provider-gate-refresh") <> ".json"
      on_exit(fn -> File.rm(path) end)
      now = DateTime.utc_now()
      stale_time = DateTime.add(now, -301, :second)
      reset_at = DateTime.add(now, 3_600, :second) |> DateTime.to_iso8601()

      assert :ok =
               ModelAvailability.observe(
                 "codex",
                 %{hourly: %{usedPercent: 100, windowDurationMins: 60, resetsAt: reset_at}},
                 path: path,
                 now: stale_time
               )

      probe = fn backend, _opts ->
        Aiur.CodexProber.probe_sync(backend, now,
          path: path,
          fetch_limits_fun: fn ->
            {:ok,
             %{
               "rateLimits" => %{
                 "primary" => %{
                   "usedPercent" => 4,
                   "windowDurationMins" => 60,
                   "resetsAt" => DateTime.to_unix(DateTime.add(now, 7_200, :second))
                 }
               }
             }}
          end
        )
      end

      assert DispatchPolicy.provider_gate(["codex"], path: path, now: now, probe_fun: probe) == :hold
      assert DispatchPolicy.provider_gate(["codex"], path: path, now: now, probe_fun: probe) == :dispatch
      assert ModelAvailability.available?("codex", path: path, now: now)
    end
  end
end
