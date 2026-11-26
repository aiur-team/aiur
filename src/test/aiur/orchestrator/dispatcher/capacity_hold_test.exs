defmodule Aiur.Orchestrator.Dispatcher.CapacityHoldTest do
  use Aiur.DispatcherTestSupport

  describe "capacity_hold surfacing" do
    defp noop_choose, do: fn state, _issues -> state end

    defp capacity_opts(test_pid, now_ms) do
      [
        emit_fun: fn name, reason -> send(test_pid, {:capacity_alert, name, reason}) end,
        telemetry_fun: fn kind, attrs -> send(test_pid, {:capacity_telemetry, kind, attrs}) end,
        alert_debounce_ms: 0,
        now_ms: now_ms
      ]
    end

    test "dispatch cycle refreshes stale provider usage before admitting ready work" do
      path = Aiur.TestSupport.tmp_root!("aiur-dispatch-provider-refresh") <> ".json"
      on_exit(fn -> File.rm(path) end)
      now = DateTime.utc_now()
      reset_at = DateTime.add(now, 3_600, :second) |> DateTime.to_unix()
      stale_at = DateTime.add(now, -301, :second)

      assert :ok =
               ModelAvailability.observe(
                 "codex",
                 %{hourly: %{usedPercent: 100, windowDurationMins: 60, resetsAt: reset_at}},
                 path: path,
                 now: stale_at
               )

      provider_probe = fn backend, opts ->
        CodexProber.probe_sync(
          backend,
          Keyword.fetch!(opts, :now),
          Keyword.put(opts, :fetch_limits_fun, fn ->
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
          end)
        )
      end

      admission_probes = fn ->
        %{
          memory_mb: 4_096,
          memory_threshold_mb: 1_024,
          fd_sample: :unavailable,
          runnable: :unavailable,
          run_queue_threshold: nil,
          schedulers: 16,
          load: 0.0,
          load_threshold: 10.0,
          build_status: %{enabled?: false, capacity: 0, active: 0, queued: 0},
          provider_backends: ["codex"],
          provider_gate_opts: [path: path, now: now, probe_fun: provider_probe],
          github_quota: :available,
          cpu_snapshot: :unavailable,
          target: nil
        }
      end

      choose = fn state, _issues ->
        send(self(), :dispatch_chosen)
        state
      end

      state = %State{max_concurrent_agents: 1, effective_concurrent_agents: 1}

      _next =
        Dispatcher.maybe_choose_under_load(state, [issue("queued-codex")], choose, admission_probes_fun: admission_probes)

      assert_received :dispatch_chosen
      assert ModelAvailability.available?("codex", path: path, now: now)
      assert ModelAvailability.load(path)["backends"]["codex"]["hourly"]["used"] == 4
    end

    test "provider capacity hold refreshes its freshness detail each dispatch cycle" do
      path = Aiur.TestSupport.tmp_root!("aiur-provider-hold-detail") <> ".json"
      on_exit(fn -> File.rm(path) end)
      now = DateTime.utc_now()
      stale_at = DateTime.add(now, -301, :second)
      reset_at = DateTime.add(now, 3_600, :second) |> DateTime.to_unix()

      assert :ok =
               ModelAvailability.observe(
                 "codex",
                 %{hourly: %{usedPercent: 100, windowDurationMins: 60, resetsAt: reset_at}},
                 path: path,
                 now: stale_at
               )

      assert :ok = ModelAvailability.schedule_retry("codex", now, path: path)

      admission_probes = fn ->
        %{
          memory_mb: 4_096,
          memory_threshold_mb: 1_024,
          fd_sample: :unavailable,
          runnable: :unavailable,
          run_queue_threshold: nil,
          schedulers: 16,
          load: 0.0,
          load_threshold: 10.0,
          build_status: %{enabled?: false, capacity: 0, active: 0, queued: 0},
          provider_backends: ["codex"],
          provider_gate_opts: [path: path, now: now],
          github_quota: :available,
          cpu_snapshot: :unavailable,
          target: nil
        }
      end

      state = %State{max_concurrent_agents: 1, effective_concurrent_agents: 1}
      queued = [issue("queued-codex")]

      first =
        Dispatcher.maybe_choose_under_load(state, queued, noop_choose(), admission_probes_fun: admission_probes)

      assert first.capacity_hold.signal == :provider
      assert first.capacity_hold.detail =~ DateTime.to_iso8601(stale_at)

      refreshed_at = DateTime.add(now, -302, :second)

      assert :ok =
               ModelAvailability.observe(
                 "codex",
                 %{hourly: %{usedPercent: 100, windowDurationMins: 60, resetsAt: reset_at}},
                 path: path,
                 now: refreshed_at
               )

      second =
        Dispatcher.maybe_choose_under_load(first, queued, noop_choose(), admission_probes_fun: admission_probes)

      assert second.capacity_hold.signal == :provider
      assert second.capacity_hold.detail =~ DateTime.to_iso8601(refreshed_at)
      refute second.capacity_hold.detail =~ DateTime.to_iso8601(stale_at)
    end

    test "a memory hold persists the limiting reason and emits a debounced backoff alert, then clears on recovery" do
      write_workflow_file!(Workflow.workflow_file_path(), min_free_memory_mb: 2_048)
      Application.put_env(:aiur, :meminfo_source_override, fn -> {:ok, "MemAvailable: 1048576 kB\n"} end)
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)

      test_pid = self()
      state = %State{max_concurrent_agents: 1, effective_concurrent_agents: 1}

      held =
        Dispatcher.maybe_choose_under_load(
          state,
          [issue("queued")],
          noop_choose(),
          capacity_opts(test_pid, 1_000)
        )

      assert %{signal: :memory, measured: 1_024, threshold: 2_048, alerted?: false} = held.capacity_hold
      refute_received {:capacity_alert, "system.fleet.capacity.backoff", _}

      # Same signal on the next poll crosses the (zeroed) debounce window.
      alerted =
        Dispatcher.maybe_choose_under_load(
          held,
          [issue("queued")],
          noop_choose(),
          capacity_opts(test_pid, 2_000)
        )

      assert alerted.capacity_hold.alerted?
      assert_received {:capacity_alert, "system.fleet.capacity.backoff", %{signal: :memory}}
      assert_received {:capacity_telemetry, :capacity_hold, %{"signal" => "memory"}}

      # Recovery: memory frees above the floor; the hold clears and reports resume.
      Application.put_env(:aiur, :meminfo_source_override, fn -> {:ok, "MemAvailable: 3145728 kB\n"} end)

      recovered =
        Dispatcher.maybe_choose_under_load(
          alerted,
          [issue("queued")],
          noop_choose(),
          capacity_opts(test_pid, 3_000)
        )

      assert recovered.capacity_hold == nil
      assert_received {:capacity_alert, "system.fleet.capacity.resumed", %{signal: :memory}}
      assert_received {:capacity_telemetry, :capacity_resumed, %{"signal" => "memory"}}
    end

    test "a saturated build gate leaves dispatch available" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_builds: 2)
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)
      Application.put_env(:aiur, :build_gate_status_override, fn -> %{enabled?: true, capacity: 2, active: 2, queued: 1} end)

      test_pid = self()
      state = %State{max_concurrent_agents: 4, effective_concurrent_agents: 4}

      held =
        Dispatcher.maybe_choose_under_load(
          state,
          [issue("queued")],
          &consume_available_slots/2,
          capacity_opts(test_pid, 1_000)
        )

      assert held.capacity_hold == nil
      assert map_size(held.running) > 0
      refute_received {:capacity_telemetry, :capacity_hold, %{"signal" => "build"}}
    end

    # #2089: an unmeasurable CPU window cannot keep a load hold alive. The hold
    # is released, the queued work is admitted, and the hold is re-asserted as
    # soon as a measured window shows contention again — so a held fleet always
    # holds on evidence, never on the absence of it.
    test "a load hold is released, not retained uncorroborated, when the next CPU sample is unavailable" do
      test_pid = self()
      previous_cpu = %{total: 1_000, idle: 700, nice: 100, runnable: 20}
      current_cpu = %{total: 1_200, idle: 710, nice: 100, runnable: 20}

      base_probes = %{
        memory_mb: :unavailable,
        memory_threshold_mb: nil,
        fd_sample: :unavailable,
        runnable: 20,
        run_queue_threshold: nil,
        schedulers: 16,
        load: 143.0,
        load_threshold: 1.5,
        build_status: %{enabled?: false, capacity: 0, active: 0, queued: 0},
        provider_backends: [],
        github_quota: :available,
        target: nil
      }

      state = %State{
        max_concurrent_agents: 8,
        effective_concurrent_agents: 8,
        load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: previous_cpu, bootstrap_complete?: true}
      }

      held =
        Dispatcher.maybe_choose_under_load(
          state,
          [issue("cpu-evidence")],
          noop_choose(),
          capacity_opts(test_pid, 1_000) ++
            [admission_probes_fun: fn -> Map.put(base_probes, :cpu_snapshot, current_cpu) end]
        )

      assert %{reclaimable_cpu_percent: 5.0, reclaimable_cpu_threshold: 60.0} = held.capacity_hold
      assert map_size(held.running) == 0

      unavailable =
        Dispatcher.maybe_choose_under_load(
          %{held | load_envelope_state: %{held.load_envelope_state | cpu_snapshot: nil}},
          [issue("cpu-evidence")],
          &consume_available_slots/2,
          capacity_opts(test_pid, 2_000) ++
            [admission_probes_fun: fn -> Map.put(base_probes, :cpu_snapshot, :unavailable) end]
        )

      assert unavailable.capacity_hold == nil
      assert map_size(unavailable.running) == 1

      recorroborated =
        Dispatcher.maybe_choose_under_load(
          %{
            unavailable
            | running: %{},
              load_envelope_state: %{unavailable.load_envelope_state | cpu_snapshot: previous_cpu}
          },
          [issue("cpu-evidence")],
          &consume_available_slots/2,
          capacity_opts(test_pid, 3_000) ++
            [admission_probes_fun: fn -> Map.put(base_probes, :cpu_snapshot, current_cpu) end]
        )

      assert %{signal: :load, reclaimable_cpu_percent: 5.0} = recorroborated.capacity_hold
      assert map_size(recorroborated.running) == 0
    end

    test "dependency-paused agents do not prevent a queued keystone from reaching dispatch selection" do
      keystone = issue("keystone")
      test_pid = self()

      state = %State{
        max_concurrent_agents: 1,
        effective_concurrent_agents: 1,
        running: %{
          "blocked-one" => dependency_paused_entry(keystone.identifier),
          "blocked-two" => dependency_paused_entry(keystone.identifier)
        }
      }

      admission_probes = fn ->
        %{
          memory_mb: :unavailable,
          memory_threshold_mb: nil,
          fd_sample: :unavailable,
          runnable: :unavailable,
          run_queue_threshold: nil,
          schedulers: 1,
          load: :unavailable,
          load_threshold: nil,
          build_status: %{enabled?: false, capacity: 0, active: 0, queued: 0},
          provider_backends: [],
          github_quota: :available,
          cpu_snapshot: :unavailable,
          target: nil
        }
      end

      selected =
        Dispatcher.maybe_choose_under_load(
          state,
          [keystone],
          &consume_available_slots/2,
          Keyword.put(capacity_opts(test_pid, 1_000), :admission_probes_fun, admission_probes)
        )

      assert Map.has_key?(selected.running, keystone.id)
    end

    test "the AIMD envelope backs off :envelope as the limiting reason while load exceeds target and work waits" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 8, target_load_average: 1.0)
      schedulers = System.schedulers_online()
      # Between the 1.0 target and the 1.5 hard-gate ceiling: the envelope backs
      # off but the hard load gate does not hold outright.
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "#{schedulers * 1.2} 1.0 1.0 1/1 1\n"} end)
      Application.put_env(:aiur, :file_descriptor_sample_override, fn -> :unavailable end)

      test_pid = self()
      state = %State{max_concurrent_agents: 8, effective_concurrent_agents: 4, load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: nil, overload_samples: 2}}

      held =
        Dispatcher.maybe_choose_under_load(
          state,
          Enum.map(1..2, &issue("queued-#{&1}")),
          &consume_available_slots/2,
          Keyword.delete(capacity_opts(test_pid, 1_000), :now_ms)
        )

      assert %{signal: :envelope, measured: 2, threshold: 8} = held.capacity_hold
      # Dispatch still proceeds up to the reduced envelope limit.
      assert map_size(held.running) == 2
    end

    test "below-target recovery does not report an envelope hold" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 8, target_load_average: 1.0)
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)
      Application.put_env(:aiur, :file_descriptor_sample_override, fn -> :unavailable end)

      test_pid = self()
      state = %State{max_concurrent_agents: 8, effective_concurrent_agents: 4}

      recovered =
        Dispatcher.maybe_choose_under_load(
          state,
          [issue("queued")],
          &consume_available_slots/2,
          Keyword.delete(capacity_opts(test_pid, 1_000), :now_ms)
        )

      assert recovered.capacity_hold == nil
      assert map_size(recovered.running) == 1
    end

    test "niced runnable load does not hard-hold but cannot widen above target" do
      test_pid = self()

      previous_cpu = %{total: 1_000, idle: 600, nice: 100, background: %{epoch: :e, daemon_nice: 0, ticks: 100, cpu_total: 1_000}, runnable: 20}
      current_cpu = %{total: 1_200, idle: 620, nice: 240, background: %{epoch: :e, daemon_nice: 0, ticks: 240, cpu_total: 1_200}, runnable: 74}

      state = %State{
        max_concurrent_agents: 8,
        effective_concurrent_agents: 4,
        load_envelope_state: %{last_decrease_ms: 1_000, cpu_snapshot: previous_cpu, bootstrap_complete?: true}
      }

      probes = fn ->
        %{
          memory_mb: :unavailable,
          memory_threshold_mb: nil,
          fd_sample: :unavailable,
          runnable: 74,
          run_queue_threshold: nil,
          schedulers: 16,
          load: 143.0,
          load_threshold: 1.5,
          build_status: %{enabled?: false, capacity: 0, active: 0, queued: 0},
          provider_backends: [],
          github_quota: :available,
          cpu_snapshot: current_cpu,
          target: 1.0
        }
      end

      recovered =
        Dispatcher.maybe_choose_under_load(
          state,
          [issue("niced-load")],
          fn next, _issues ->
            send(test_pid, :dispatched)
            next
          end,
          admission_probes_fun: probes,
          now_ms: 2_000
        )

      assert_received :dispatched
      assert %{signal: :envelope, measured: 4, threshold: 8} = recovered.capacity_hold
      assert recovered.effective_concurrent_agents == 4
    end

    test "hard load admission samples CPU when the adaptive envelope is disabled" do
      workflow_path = Workflow.workflow_file_path()
      write_workflow_file!(workflow_path, max_concurrent_agents: 8)

      workflow =
        workflow_path
        |> File.read!()
        |> String.replace("agent:\n", "agent:\n  max_load_average: 1.5\n  target_load_average: null\n")

      File.write!(workflow_path, workflow)
      :ok = Aiur.WorkflowStore.force_reload(5_000)

      schedulers = System.schedulers_online()
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "#{schedulers * 9.0} 1.0 1.0 1/1 1\n"} end)

      Application.put_env(:aiur, :proc_stat_source_override, fn -> {:ok, "cpu 240 240 100 620 0 0 0 0 0 0\nprocs_running 74\n"} end)
      Application.put_env(:aiur, :background_cpu_source_override, fn -> %{epoch: :e, daemon_nice: 0, ticks: 240, cpu_total: 1_200} end)
      Application.put_env(:aiur, :file_descriptor_sample_override, fn -> :unavailable end)

      previous_cpu = %{total: 1_000, idle: 600, nice: 100, background: %{epoch: :e, daemon_nice: 0, ticks: 100, cpu_total: 1_000}, runnable: 20}

      state = %State{
        max_concurrent_agents: 8,
        effective_concurrent_agents: 8,
        load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: previous_cpu, bootstrap_complete?: true}
      }

      recovered =
        Dispatcher.maybe_choose_under_load(state, [issue("hard-gate-niced-load")], fn next, _issues ->
          send(self(), :hard_gate_dispatched)
          next
        end)

      assert_received :hard_gate_dispatched
      assert recovered.capacity_hold == nil
    end
  end
end
