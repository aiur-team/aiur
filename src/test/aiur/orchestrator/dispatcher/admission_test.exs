defmodule Aiur.Orchestrator.Dispatcher.AdmissionTest do
  use Aiur.DispatcherTestSupport

  describe "CPU headroom recovery integration" do
    test "a second CPU sample re-ramps and consumes restored slots in the same poll" do
      write_workflow_file!(Workflow.workflow_file_path(),
        max_concurrent_agents: 8,
        target_load_average: 1.0,
        load_ramp_step: 1
      )

      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)
      Application.put_env(:aiur, :file_descriptor_sample_override, fn -> :unavailable end)

      {:ok, samples} =
        Agent.start_link(fn ->
          [
            "cpu 100 0 100 800 0 0 0 0 0 0\nprocs_running 1\n",
            "cpu 120 0 120 960 0 0 0 0 0 0\nprocs_running 1\n"
          ]
        end)

      Application.put_env(:aiur, :proc_stat_source_override, fn ->
        Agent.get_and_update(samples, fn [sample | rest] -> {{:ok, sample}, rest} end)
      end)

      running = Map.new(1..4, fn index -> {"active-#{index}", running_entry("active-#{index}")} end)
      queued = Enum.map(1..4, &issue("queued-#{&1}"))

      state = %State{
        max_concurrent_agents: 8,
        effective_concurrent_agents: 4,
        load_envelope_state: %{last_decrease_ms: 1_000, cpu_snapshot: nil},
        running: running
      }

      first = Dispatcher.maybe_choose_under_load(state, queued, &consume_available_slots/2)
      assert first.effective_concurrent_agents == 5
      assert map_size(first.running) == 5

      second = Dispatcher.maybe_choose_under_load(first, queued, &consume_available_slots/2)
      assert second.effective_concurrent_agents == 8
      assert map_size(second.running) == 8
      assert second.load_envelope_state.last_decrease_ms == nil
    end
  end

  describe "memory admission" do
    test "holds a normal dispatch cycle below the configured floor" do
      write_workflow_file!(Workflow.workflow_file_path(), min_free_memory_mb: 2_048)
      Application.put_env(:aiur, :meminfo_source_override, fn -> {:ok, "MemAvailable: 1048576 kB\n"} end)
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)

      state = %State{max_concurrent_agents: 1, effective_concurrent_agents: 1}

      log =
        capture_log(fn ->
          assert %State{running: %{}} = Dispatcher.maybe_choose_under_load(state, [])
        end)

      assert log =~ "aiur_perf memory_hold surface=dispatch available_mb=1024 threshold_mb=2048"
    end
  end

  describe "file-descriptor admission" do
    test "holds below the reserve, logs the sample, and recovers on a later cycle" do
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)

      Application.put_env(:aiur, :file_descriptor_sample_override, fn ->
        %{pid: "123", used: 91, limit: 100, available: 9, headroom_ratio: 0.09}
      end)

      state = %State{max_concurrent_agents: 1, effective_concurrent_agents: 1}

      hold_log =
        capture_log(fn ->
          assert %State{running: %{}} = Dispatcher.maybe_choose_under_load(state, [])
        end)

      assert hold_log =~
               "aiur_perf fd_hold surface=dispatch used=91 limit=100 available=9 threshold=10 threshold_pct=10"

      Application.put_env(:aiur, :file_descriptor_sample_override, fn ->
        %{pid: "123", used: 90, limit: 100, available: 10, headroom_ratio: 0.10}
      end)

      recovery_log =
        capture_log(fn ->
          assert %State{running: %{}} = Dispatcher.maybe_choose_under_load(state, [])
        end)

      refute recovery_log =~ "aiur_perf fd_hold"
    end

    test "holds when the sample itself reports descriptor exhaustion" do
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)
      Application.put_env(:aiur, :file_descriptor_sample_override, fn -> :exhausted end)

      log =
        capture_log(fn ->
          assert %State{running: %{}} =
                   Dispatcher.maybe_choose_under_load(
                     %State{max_concurrent_agents: 1, effective_concurrent_agents: 1},
                     []
                   )
        end)

      assert log =~
               "aiur_perf fd_hold surface=dispatch status=exhausted used=unknown limit=unknown available=0 threshold=unknown threshold_pct=10"
    end
  end

  # #2089: `Orchestrator` dropped queued work under host CPU load. The mechanism
  # was the FIRST admission decision a `State` ever makes: `put_cpu_headroom/2`
  # has no earlier `/proc/stat` snapshot to diff against, so the corroborating
  # measurement is `:unavailable`, and an unavailable corroboration used to be
  # treated as confirmation of the raw load-average hold. On a box whose 1-minute
  # average is over `max_load_average * schedulers` — routine while the fleet
  # ramps — the very cycle that should start work returned an empty `running`
  # map with a `%{signal: :load}` `capacity_hold` and no CPU evidence behind it.
  describe "startup sample freshness (#3521)" do
    test "boot with ready candidates cannot widen on a frozen load sample" do
      ready = for id <- 1..16, do: issue("frozen-#{id}")
      probes = contended_probes(0.0, %{total: 1_100, idle: 600, nice: 0, runnable: 1}).()
      probes = %{probes | target: 1.0} |> Map.put(:sampled_at_ms, 1_000)
      initial = %State{max_concurrent_agents: 16, effective_concurrent_agents: 1, poll_interval_ms: 1_000}

      result =
        Enum.reduce([1_000, 1_500, 2_001, 10_000], initial, fn now, state ->
          Dispatcher.maybe_choose_under_load(state, ready, &consume_available_slots/2, admission_probes_fun: fn -> probes end, now_ms: now)
        end)

      assert map_size(result.running) == 1
      assert result.effective_concurrent_agents == 1

      refreshed = Dispatcher.maybe_choose_under_load(result, ready, &consume_available_slots/2, admission_probes_fun: fn -> %{probes | sampled_at_ms: 11_000} end, now_ms: 11_000)
      assert map_size(refreshed.running) == 2
    end

    test "a sample already older than one period cannot widen the boot envelope" do
      probes = contended_probes(0.0, :unavailable).() |> Map.put(:target, 1.0) |> Map.put(:sampled_at_ms, 0)
      state = %State{max_concurrent_agents: 16, effective_concurrent_agents: 1, poll_interval_ms: 1_000}
      result = Dispatcher.maybe_choose_under_load(state, [issue("stale-boot")], &consume_available_slots/2, admission_probes_fun: fn -> probes end, now_ms: 1_001)
      assert result.effective_concurrent_agents == 1
      assert map_size(result.running) == 1
    end

    test "candidate authorization stops while the mailbox is deep" do
      for _ <- 1..100, do: send(self(), :backlog_3521)
      parent = self()
      state = %State{max_concurrent_agents: 16, effective_concurrent_agents: 16}

      result =
        Dispatcher.choose_issues(state, [issue("backlogged")],
          issue_fetcher: fn _ ->
            send(parent, :unexpected_authorization_3521)
            {:ok, []}
          end
        )

      for _ <- 1..100 do
        receive do
          :backlog_3521 -> :ok
        end
      end

      assert result.running == %{}
      refute_received :unexpected_authorization_3521
    end

    test "candidate authorization stops when a batch sample expires" do
      parent = self()
      state = %State{max_concurrent_agents: 16, effective_concurrent_agents: 16, poll_interval_ms: 1_000}
      state = put_in(state.load_envelope_state[:sampled_at_ms], System.monotonic_time(:millisecond) - 1_001)

      Dispatcher.choose_issues(state, [issue("expired-batch")],
        issue_fetcher: fn _ ->
          send(parent, :unexpected_authorization_3521)
          {:ok, []}
        end
      )

      refute_received :unexpected_authorization_3521
    end
  end

  describe "ramp-from-zero admission (#2089)" do
    setup do
      # A load average far over the ceiling, with a valid CPU snapshot whose
      # window cannot be measured yet because the state has no baseline.
      probes = fn ->
        %{
          memory_mb: :unavailable,
          memory_threshold_mb: nil,
          fd_sample: :unavailable,
          runnable: 200,
          run_queue_threshold: 1.5,
          schedulers: 4,
          load: 143.0,
          load_threshold: 1.5,
          build_status: %{enabled?: false, capacity: 0, active: 0, queued: 0},
          provider_backends: [],
          github_quota: :available,
          cpu_snapshot: %{total: 1_200, idle: 710, nice: 100, runnable: 200},
          target: nil
        }
      end

      %{probes: probes, queued: issue("ramp-from-zero")}
    end

    test "dispatches queued work on the first cycle, before any CPU window exists", %{
      probes: probes,
      queued: queued
    } do
      # `cpu_snapshot: nil` is the State default, i.e. a freshly booted
      # orchestrator or any handler that builds its own state.
      state = %State{
        max_concurrent_agents: 4,
        effective_concurrent_agents: 4,
        load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: nil, bootstrap_complete?: false}
      }

      next =
        Dispatcher.maybe_choose_under_load(
          state,
          [queued],
          &consume_available_slots/2,
          admission_probes_fun: probes
        )

      assert Map.has_key?(next.running, queued.id)
      assert next.capacity_hold == nil
      assert next.dispatch_capacity_constraints == []
    end

    test "still holds the same load once the window is measurable and shows contention", %{
      probes: probes,
      queued: queued
    } do
      # Identical probes; the only difference is a baseline the window can be
      # measured against. 10 idle jiffies out of 200 is 5% reclaimable, so the
      # hold is now backed by a measurement — a fix that simply stopped holding
      # would fail here.
      state = %State{
        max_concurrent_agents: 4,
        effective_concurrent_agents: 4,
        load_envelope_state: %{
          last_decrease_ms: nil,
          cpu_snapshot: %{total: 1_000, idle: 700, nice: 100, runnable: 200},
          bootstrap_complete?: true
        }
      }

      next =
        Dispatcher.maybe_choose_under_load(
          state,
          [queued],
          &consume_available_slots/2,
          admission_probes_fun: probes
        )

      assert next.running == %{}

      assert %{signal: :run_queue, reclaimable_cpu_percent: 5.0, reclaimable_cpu_threshold: 60.0} =
               next.capacity_hold
    end
  end
end
