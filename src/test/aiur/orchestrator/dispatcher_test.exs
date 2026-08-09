defmodule Aiur.Orchestrator.DispatcherTest do
  use Aiur.TestSupport

  import ExUnit.CaptureLog

  alias Aiur.AgentRunner.{SessionLifecycle, ToolExecutor}
  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.GitHub.CiReadiness
  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, IssueSync, State, StatusReport, TrackerHealth}
  alias Aiur.RunTelemetry.Lifecycle, as: TelemetryLifecycle

  setup do
    CiReadiness.clear_cached_result()
    previous_meminfo = Application.get_env(:aiur, :meminfo_source_override)
    previous_loadavg = Application.get_env(:aiur, :loadavg_source_override)
    previous_fd_sample = Application.get_env(:aiur, :file_descriptor_sample_override)
    previous_proc_stat = Application.get_env(:aiur, :proc_stat_source_override)
    previous_build_status = Application.get_env(:aiur, :build_gate_status_override)
    previous_lifecycle_recorder = Application.get_env(:aiur, :run_telemetry_lifecycle_recorder)
    previous_ci_readiness_check_fun = Application.get_env(:aiur, :ci_readiness_check_fun)

    # Dispatch must not shell out to the real build-gate lock files on every
    # poll; default to a free (fail-open) gate status and override per-test.
    Application.put_env(:aiur, :build_gate_status_override, fn ->
      %{enabled?: false, capacity: 0, active: 0, queued: 0}
    end)

    on_exit(fn ->
      restore_app_env(:meminfo_source_override, previous_meminfo)
      restore_app_env(:loadavg_source_override, previous_loadavg)
      restore_app_env(:file_descriptor_sample_override, previous_fd_sample)
      restore_app_env(:proc_stat_source_override, previous_proc_stat)
      restore_app_env(:build_gate_status_override, previous_build_status)
      restore_app_env(:run_telemetry_lifecycle_recorder, previous_lifecycle_recorder)
      restore_app_env(:ci_readiness_check_fun, previous_ci_readiness_check_fun)
      CiReadiness.clear_cached_result()
    end)

    :ok
  end

  defp dispatch_recovery(codex_thrash_budget) do
    %{
      workspace_ownership: %{waits: %{}, ready: %{}},
      codex_thrash_budget: codex_thrash_budget
    }
  end

  test "first dispatch warns about an unmergeable GitHub repository without blocking dispatch" do
    readiness = %{ready?: false, base_branch: "develop", issues: [:no_pr_workflow]}
    emit = fn name, opts -> send(self(), {:ci_readiness_alert, name, opts}) end

    state = Dispatcher.check_initial_ci_readiness(%State{}, "github", "develop", fn _ -> {:ok, readiness} end, emit)

    assert state.ci_readiness_checked
    assert_receive {:ci_readiness_alert, "system.ci_readiness.not_ready", opts}
    assert opts[:needs_attention]
    assert opts[:reason] =~ "no workflow triggers on pull_request"
  end

  test "initial readiness scan runs outside the dispatcher mailbox and caches its result" do
    parent = self()
    readiness = %{ready?: true, base_branch: "develop", issues: []}

    state =
      Dispatcher.start_initial_ci_readiness_check(%State{}, "github", "develop", fn _opts ->
        send(parent, :readiness_scan_started)
        {:ok, readiness}
      end)

    assert is_pid(state.ci_readiness_check_pid)
    assert_receive :readiness_scan_started
    assert_receive {:ci_readiness_result, token, {:ok, ^readiness}}

    state = Dispatcher.handle_ci_readiness_result(state, token, {:ok, readiness})

    assert state.ci_readiness_checked
    assert CiReadiness.cached_result(base_branch: "develop") == readiness
  end

  test "first dispatch retries an unavailable readiness check without duplicate alerts" do
    emit = fn name, _opts -> send(self(), {:ci_readiness_alert, name}) end
    state = Dispatcher.check_initial_ci_readiness(%State{}, "github", "develop", fn _ -> {:error, :timeout} end, emit)

    refute state.ci_readiness_checked
    assert state.ci_readiness_unavailable_alerted
    assert is_integer(state.ci_readiness_retry_at_ms)
    assert_receive {:ci_readiness_alert, "system.ci_readiness.unavailable"}

    state = Dispatcher.check_initial_ci_readiness(state, "github", "develop", fn _ -> {:error, :timeout} end, emit)

    refute state.ci_readiness_checked
    refute_receive {:ci_readiness_alert, _}
  end

  test "does not launch another readiness scan before the transient retry deadline" do
    scope = CiReadiness.readiness_scope()
    state = %State{ci_readiness_retry_at_ms: System.monotonic_time(:millisecond) + 60_000, ci_readiness_scope: scope}

    assert Dispatcher.maybe_warn_ci_readiness(state) == state
  end

  test "paces retryable GitHub readiness errors without caching them as permanent" do
    emit = fn name, _opts -> send(self(), {:ci_readiness_alert, name}) end
    error = {:github, :rate_limited, %{status: 429}}

    state = Dispatcher.check_initial_ci_readiness(%State{}, "github", "develop", fn _ -> {:error, error} end, emit)

    refute state.ci_readiness_checked
    assert is_integer(state.ci_readiness_retry_at_ms)
    assert CiReadiness.cached_result() == :unavailable
    assert_receive {:ci_readiness_alert, "system.ci_readiness.unavailable"}
  end

  test "retries transient GitHub server errors without caching them as permanent" do
    emit = fn name, _opts -> send(self(), {:ci_readiness_alert, name}) end
    error = {:github, :http, %{status: 503}}

    state = Dispatcher.check_initial_ci_readiness(%State{}, "github", "develop", fn _ -> {:error, error} end, emit)

    refute state.ci_readiness_checked
    assert is_integer(state.ci_readiness_retry_at_ms)
    assert CiReadiness.cached_result() == :unavailable
    assert_receive {:ci_readiness_alert, "system.ci_readiness.unavailable"}
  end

  test "caches an operator-token readiness gap as a completed assessment" do
    readiness = CiReadiness.unavailable("develop", :ci_readiness_operator_token_required)
    emit = fn name, opts -> send(self(), {:ci_readiness_alert, name, opts}) end

    state = Dispatcher.check_initial_ci_readiness(%State{}, "github", "develop", fn _ -> {:ok, readiness} end, emit)

    assert state.ci_readiness_checked
    assert CiReadiness.cached_result(base_branch: "develop") == readiness
    assert_receive {:ci_readiness_alert, "system.ci_readiness.not_ready", opts}
    assert opts[:needs_attention]
  end

  test "a completed readiness assessment is rescanned after its cache expires" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_base_branch: "develop"
    )

    parent = self()
    old_readiness = %{ready?: true, base_branch: "develop", issues: []}
    new_readiness = %{ready?: false, base_branch: "develop", issues: [:no_required_check]}
    assessed_at = DateTime.add(DateTime.utc_now(), -3_601, :second)
    opts = [base_branch: "develop", now: assessed_at]
    scope = CiReadiness.readiness_scope(opts)

    assert :ok = CiReadiness.persist_assessment(old_readiness, opts)

    Application.put_env(:aiur, :ci_readiness_check_fun, fn check_opts ->
      send(parent, {:readiness_rescan, check_opts})
      {:ok, new_readiness}
    end)

    state = %State{
      ci_readiness_checked: true,
      ci_readiness_scope: scope,
      ci_readiness_result: old_readiness
    }

    state = Dispatcher.maybe_warn_ci_readiness(state)

    refute state.ci_readiness_checked
    assert is_pid(state.ci_readiness_check_pid)
    assert_receive {:readiness_rescan, check_opts}
    assert check_opts[:base_branch] == "develop"
  end

  test "a newer operator assessment replaces the completed live result" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_base_branch: "develop"
    )

    now = DateTime.utc_now()
    old_readiness = CiReadiness.unavailable("develop", :ci_readiness_operator_token_required)
    new_readiness = %{ready?: true, base_branch: "develop", issues: []}
    opts = [base_branch: "develop", now: DateTime.add(now, -2, :second)]
    scope = CiReadiness.readiness_scope(opts)

    assert :ok = CiReadiness.cache_result(old_readiness, opts)
    assert :ok = CiReadiness.persist_assessment(new_readiness, Keyword.put(opts, :now, DateTime.add(now, -1, :second)))

    state = %State{
      ci_readiness_checked: true,
      ci_readiness_scope: scope,
      ci_readiness_result: old_readiness
    }

    assert %State{ci_readiness_checked: true, ci_readiness_result: ^new_readiness} =
             Dispatcher.maybe_warn_ci_readiness(state)
  end

  test "GitHub candidate state is fetched authoritatively every configured poll interval" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_active_states: ["todo", "in-progress", "rework", "merging"],
      poll_interval_seconds: 5
    )

    cached = %Issue{id: "42", identifier: "42", title: "Cached", state: "in-progress"}
    fresh = %{cached | state: "todo", labels: ["agent:todo"]}

    state = %State{
      poll_interval_ms: 5_000,
      candidate_snapshot_fresh?: false,
      ci_lifecycle: %{
        approved_heads: %{},
        test_failure_heads: %{},
        base_repair_invalidations: %{},
        poll_cache: %{issue_list_cache: %{stale: cached}},
        rewakes: %{}
      }
    }

    {:ok, responses} = Agent.start_link(fn -> [{[cached], %{etag: "v1"}}, {[fresh], %{etag: "v2"}}] end)

    fetch_fun = fn cache ->
      Agent.get_and_update(responses, fn [{issues, updated_cache} | rest] ->
        assert cache == if(issues == [cached], do: %{}, else: %{etag: "v1"})
        {{:ok, issues, updated_cache}, rest}
      end)
    end

    assert {:ok, [^cached], state} = Dispatcher.fetch_candidate_issues(state, fetch_fun: fetch_fun)
    assert state.candidate_snapshot_fresh?
    assert state.ci_lifecycle.poll_cache.candidate_list_cache == %{etag: "v1"}

    assert {:ok, [^fresh], state} = Dispatcher.fetch_candidate_issues(state, fetch_fun: fetch_fun)
    assert state.ci_lifecycle.poll_cache.candidate_list_cache == %{etag: "v2"}

    assert TrackerHealth.next_poll_delay_ms(state) == 5_000
  end

  test "a failed GitHub candidate refresh hides stale idle labels but preserves recovery data" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_active_states: ["todo", "in-progress", "rework", "merging"]
    )

    stale = %Issue{id: "42", identifier: "42", title: "Stale", state: "in-progress"}

    state = %State{
      last_polled_issues: %{stale.id => stale},
      snapshot_ready?: false,
      ci_lifecycle: %{
        %State{}.ci_lifecycle
        | poll_cache: %{candidate_list_cache: %{pages: %{1 => %{etag: "v1"}}}}
      }
    }

    reason = {:github, :timeout, %{reason: :timeout}}
    fetch_fun = fn %{pages: %{1 => %{etag: "v1"}}} -> {:error, reason} end

    assert {:error, ^reason, next} =
             Dispatcher.fetch_candidate_issues(state, fetch_fun: fetch_fun)

    assert next.last_polled_issues == state.last_polled_issues
    assert next.snapshot_ready?
    refute next.candidate_snapshot_fresh?
    assert next.ci_lifecycle.poll_cache == state.ci_lifecycle.poll_cache
    assert next.github_connectivity[:candidates] == {:timeout, 1}
    assert next.github_poll_delays[:candidates] == 1_000

    assert %{idle: [], polling: %{tracker_snapshot_fresh?: false}} =
             StatusReport.snapshot_payload(next)

    assert StatusReport.running_summaries(next) == []
  end

  defp thrash_budget(state), do: state.dispatch_recovery.codex_thrash_budget

  describe "prewarm dispatch halt" do
    test "emits once while prewarm keeps the fleet on hold and rearms after recovery" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("system.dispatch.prewarm_blocked")
      :ok = Exchange.subscribe("system.dispatch.prewarm_blocked.resolved")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      held = Dispatcher.emit_prewarm_blocked_alert(%State{}, :building)
      assert held.prewarm_blocked_alert_active
      assert_receive {:event, %{topic: "system.dispatch.prewarm_blocked"} = event}, 500
      assert event["reason"] =~ "Prewarm is building"

      assert Dispatcher.emit_prewarm_blocked_alert(held, :building) == held
      refute_receive {:event, %{topic: "system.dispatch.prewarm_blocked"}}, 100

      recovered = Dispatcher.clear_prewarm_blocked_alert(held)
      refute recovered.prewarm_blocked_alert_active
      assert recovered.prewarm_blocked_alert_resolution_emitted
      assert_receive {:event, %{topic: "system.dispatch.prewarm_blocked.resolved"}}, 500

      rearmed = Dispatcher.emit_prewarm_blocked_alert(recovered, :building)
      assert_receive {:event, %{topic: "system.dispatch.prewarm_blocked"}}, 500
      refute rearmed.prewarm_blocked_alert_resolution_emitted
    end
  end

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

  describe "capacity constraint sampling" do
    test "preserves a load gate age while memory and FD holds mask admission" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("system.dispatch.capacity_starved")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      {:ok, admission_samples} =
        Agent.start_link(fn ->
          [
            %{memory_mb: 4_000, fd_sample: :unavailable},
            %{memory_mb: 1_024, fd_sample: :unavailable},
            %{memory_mb: 4_000, fd_sample: :exhausted},
            %{memory_mb: 4_000, fd_sample: :unavailable}
          ]
        end)

      admission_probes = fn ->
        Agent.get_and_update(admission_samples, fn [sample | rest] -> {sample, rest} end)
        |> Map.merge(%{
          memory_threshold_mb: 2_048,
          runnable: :unavailable,
          run_queue_threshold: nil,
          schedulers: 4,
          load: 10_000.0,
          load_threshold: 1.0,
          build_status: %{enabled?: false, capacity: 0, active: 0, queued: 0},
          provider_backends: [],
          cpu_snapshot: :unavailable,
          target: nil
        })
      end

      ready = issue("persistent-load")

      sample = fn state ->
        state
        |> Map.put(:dispatch_capacity_constraints, [])
        |> Dispatcher.maybe_choose_under_load(
          [ready],
          fn sampled, _issues -> sampled end,
          admission_probes_fun: admission_probes
        )
      end

      waiting =
        %State{max_concurrent_agents: 1, effective_concurrent_agents: 1}
        |> sample.()
        |> IssueSync.sync_capacity_starvation_alert([ready], 1_000)

      assert Enum.any?(waiting.dispatch_capacity_constraints, &(&1.kind == :load))

      memory_masked =
        waiting
        |> sample.()
        |> IssueSync.sync_capacity_starvation_alert([ready], 30_000)

      assert Enum.any?(memory_masked.dispatch_capacity_constraints, &(&1.kind == :load))
      assert Enum.any?(memory_masked.dispatch_capacity_constraints, &(&1.kind == :memory))

      fd_masked =
        memory_masked
        |> sample.()
        |> IssueSync.sync_capacity_starvation_alert([ready], 45_000)

      assert Enum.any?(fd_masked.dispatch_capacity_constraints, &(&1.kind == :load))
      assert Enum.any?(fd_masked.dispatch_capacity_constraints, &(&1.kind == :fd))

      alerted =
        fd_masked
        |> sample.()
        |> IssueSync.sync_capacity_starvation_alert([ready], 61_000)

      assert alerted.capacity_starvation.alerted == ["load"]
      assert alerted.capacity_starvation.since_ms == %{"load" => 1_000}
      assert_receive {:event, %{topic: "system.dispatch.capacity_starved"} = event}, 500
      assert event["reason"] =~ "load gate"
    end

    # `admission_gate/1` can bind on gates that have no standalone probe. Without
    # recording the binding signal, a fleet held by one of them reports zero
    # constraints and `sync_capacity_starvation_alert/3` clears starvation
    # instead of alerting — the fleet is stuck and nothing says so.
    test "a build-queue hold still records a constraint and starves" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("system.dispatch.capacity_starved")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_builds: 2)
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)
      Application.put_env(:aiur, :file_descriptor_sample_override, fn -> :unavailable end)

      Application.put_env(:aiur, :build_gate_status_override, fn ->
        %{enabled?: true, capacity: 2, active: 2, queued: 1}
      end)

      ready = issue("build-queued")

      sample = fn state ->
        state
        |> Map.put(:dispatch_capacity_constraints, [])
        |> Dispatcher.maybe_choose_under_load([ready], fn sampled, _issues -> sampled end)
      end

      held =
        %State{max_concurrent_agents: 4, effective_concurrent_agents: 4}
        |> sample.()
        |> IssueSync.sync_capacity_starvation_alert([ready], 1_000)

      assert Enum.any?(held.dispatch_capacity_constraints, &(&1.kind == :build_queue))

      alerted =
        held
        |> sample.()
        |> IssueSync.sync_capacity_starvation_alert([ready], 61_000)

      assert alerted.capacity_starvation.alerted == ["build-queue"]
      assert_receive {:event, %{topic: "system.dispatch.capacity_starved"} = event}, 500
      assert event["reason"] =~ "build-queue gate"
    end

    test "keeps a persistent build-queue age while a higher-priority memory gate oscillates" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("system.dispatch.capacity_starved")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        max_concurrent_builds: 2,
        min_free_memory_mb: 2_048
      )

      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)
      Application.put_env(:aiur, :file_descriptor_sample_override, fn -> :unavailable end)

      # The build queue stays saturated for the whole window; memory drops out
      # and recovers around it. Memory outranks build in `admission_gate/1`, so
      # before every failing gate was sampled independently the build-queue
      # identity vanished from the constraint set on the memory ticks and its
      # age restarted — suppressing the alert for as long as memory oscillated.
      Application.put_env(:aiur, :build_gate_status_override, fn ->
        %{enabled?: true, capacity: 2, active: 2, queued: 1}
      end)

      {:ok, memory_samples} =
        Agent.start_link(fn ->
          ["MemAvailable: 4096000 kB\n", "MemAvailable: 1048576 kB\n", "MemAvailable: 4096000 kB\n"]
        end)

      Application.put_env(:aiur, :meminfo_source_override, fn ->
        Agent.get_and_update(memory_samples, fn [sample | rest] -> {{:ok, sample}, rest} end)
      end)

      ready = issue("build-starved")

      sample = fn state ->
        state
        |> Map.put(:dispatch_capacity_constraints, [])
        |> Dispatcher.maybe_choose_under_load([ready], fn sampled, _issues -> sampled end)
      end

      held =
        %State{max_concurrent_agents: 4, effective_concurrent_agents: 4}
        |> sample.()
        |> IssueSync.sync_capacity_starvation_alert([ready], 1_000)

      assert Enum.any?(held.dispatch_capacity_constraints, &(&1.kind == :build_queue))

      masked =
        held
        |> sample.()
        |> IssueSync.sync_capacity_starvation_alert([ready], 30_000)

      # Memory is binding on this tick, but the build queue must still be
      # recorded so its age survives.
      assert Enum.any?(masked.dispatch_capacity_constraints, &(&1.kind == :memory))
      assert Enum.any?(masked.dispatch_capacity_constraints, &(&1.kind == :build_queue))
      assert masked.capacity_starvation.since_ms["build-queue"] == 1_000

      alerted =
        masked
        |> sample.()
        |> IssueSync.sync_capacity_starvation_alert([ready], 61_000)

      assert "build-queue" in alerted.capacity_starvation.alerted
      assert_receive {:event, %{topic: "system.dispatch.capacity_starved"} = event}, 500
      assert event["reason"] =~ "build-queue gate"
    end
  end

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

    test "a saturated build gate defers dispatch and reports :build as the limiting reason" do
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

      assert %{signal: :build, threshold: 2} = held.capacity_hold
      assert map_size(held.running) == 0
      assert_received {:capacity_telemetry, :capacity_hold, %{"signal" => "build"}}
    end

    test "the AIMD envelope backs off :envelope as the limiting reason while load exceeds target and work waits" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 8, target_load_average: 1.0)
      schedulers = System.schedulers_online()
      # Between the 1.0 target and the 1.5 hard-gate ceiling: the envelope backs
      # off but the hard load gate does not hold outright.
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "#{schedulers * 1.2} 1.0 1.0 1/1 1\n"} end)
      Application.put_env(:aiur, :file_descriptor_sample_override, fn -> :unavailable end)

      test_pid = self()
      state = %State{max_concurrent_agents: 8, effective_concurrent_agents: 4}

      held =
        Dispatcher.maybe_choose_under_load(
          state,
          Enum.map(1..2, &issue("queued-#{&1}")),
          &consume_available_slots/2,
          capacity_opts(test_pid, 1_000)
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
          capacity_opts(test_pid, 1_000)
        )

      assert recovered.capacity_hold == nil
      assert map_size(recovered.running) == 1
    end
  end

  describe "prewarm hold observability" do
    # Mirrors Dispatcher's @prewarm_hold_log_interval_ticks; kept literal so a
    # change to the production interval is a deliberate, visible edit here too.
    @hold_log_interval 30

    test "logs the hold reason at most once per hold-log interval" do
      with_prewarm_enabled_config()

      {:ok, log_messages} = Agent.start_link(fn -> [] end)
      log_fun = fn message -> Agent.update(log_messages, &[message | &1]) end
      ready = issue("prewarm-probe")

      admission_probes = fn ->
        %{
          memory_mb: 1_024,
          memory_threshold_mb: 2_048,
          fd_sample: :unavailable,
          runnable: :unavailable,
          run_queue_threshold: nil,
          schedulers: 4,
          load: :unavailable,
          load_threshold: nil,
          build_status: %{enabled?: false, capacity: 0, active: 0, queued: 0},
          provider_backends: [],
          cpu_snapshot: :unavailable,
          target: nil
        }
      end

      hold = fn acc ->
        Dispatcher.dispatch_or_hold(acc, [ready], fn -> :building end,
          log_fun: log_fun,
          admission_probes_fun: admission_probes
        )
      end

      # 30 consecutive holds (ticks 1..30) log only on the first tick.
      state =
        Enum.reduce(1..@hold_log_interval, %State{}, fn _i, acc ->
          hold.(acc)
        end)

      assert state.prewarm_hold_ticks == @hold_log_interval
      assert Enum.any?(state.dispatch_capacity_constraints, &(&1.kind == :memory))

      assert Agent.get(log_messages, fn messages ->
               Enum.count(messages, &String.contains?(&1, "aiur_perf prewarm_hold"))
             end) == 1

      assert Agent.get(log_messages, &hd/1) == "aiur_perf prewarm_hold surface=dispatch phase=:building"

      Agent.update(log_messages, fn _messages -> [] end)

      # A second window (ticks 31..60) adds exactly one more line.
      state =
        Enum.reduce(1..(@hold_log_interval * 2), %State{}, fn _i, acc ->
          hold.(acc)
        end)

      assert state.prewarm_hold_ticks == @hold_log_interval * 2

      assert Agent.get(log_messages, fn messages ->
               Enum.count(messages, &String.contains?(&1, "aiur_perf prewarm_hold"))
             end) == 2
    end

    test "uses Logger by default for the hold observation" do
      phase = {:default_logger, System.unique_integer([:positive])}

      log = capture_log(fn -> Dispatcher.log_prewarm_hold(%State{}, phase) end)

      assert log =~ "aiur_perf prewarm_hold surface=dispatch phase=#{inspect(phase)}"
    end

    test "fails open to a cold clone on a base-build error and resets the hold counter" do
      with_prewarm_enabled_config()
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)
      Application.put_env(:aiur, :file_descriptor_sample_override, fn -> :unavailable end)

      state = %State{
        max_concurrent_agents: 1,
        effective_concurrent_agents: 1,
        prewarm_hold_ticks: 25
      }

      log =
        capture_log(fn ->
          next = Dispatcher.dispatch_or_hold(state, [], fn -> {:error, :base_build_failed} end)
          assert next.prewarm_hold_ticks == 0
        end)

      assert log =~ "prewarm base unavailable"
      assert log =~ "dispatching via cold clone"
    end

    test "resets the hold counter once the base is ready" do
      with_prewarm_enabled_config()
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)
      Application.put_env(:aiur, :file_descriptor_sample_override, fn -> :unavailable end)

      state = %State{
        max_concurrent_agents: 1,
        effective_concurrent_agents: 1,
        prewarm_hold_ticks: 10
      }

      next = Dispatcher.dispatch_or_hold(state, [], fn -> :ready end)
      assert next.prewarm_hold_ticks == 0
    end

    test "does not hold or log when prewarm is disabled" do
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)
      Application.put_env(:aiur, :file_descriptor_sample_override, fn -> :unavailable end)

      state = %State{
        max_concurrent_agents: 1,
        effective_concurrent_agents: 1,
        prewarm_hold_ticks: 7
      }

      log =
        capture_log(fn ->
          next = Dispatcher.dispatch_or_hold(state, [], fn -> :building end)
          assert next.prewarm_hold_ticks == 0
        end)

      refute log =~ "aiur_perf prewarm_hold"
    end
  end

  describe "check_thrash_budget/3" do
    test "counts dispatches within window and trips over the threshold" do
      state = %State{}
      issue_id = "issue-1"
      now_ms = 0
      # Default threshold is 6; 7 calls should trip
      {state, result} =
        Enum.reduce(1..7, {state, nil}, fn _i, {acc_state, _} ->
          case Dispatcher.check_thrash_budget(acc_state, issue_id, now_ms) do
            {:ok, next} -> {next, :ok}
            {:trip, next} -> {next, :trip}
          end
        end)

      assert result == :trip
      assert get_in(thrash_budget(state), [issue_id, :count]) == 6
      assert get_in(thrash_budget(state), [issue_id, :tripped]) == :window
    end

    test "resets the window when enough time has lapsed" do
      state = %State{
        dispatch_recovery: dispatch_recovery(%{"issue-1" => %{window_start_ms: 0, count: 10}})
      }

      # 61_000ms > default 60-second window
      assert {:ok, next_state} =
               Dispatcher.check_thrash_budget(state, "issue-1", 61_000)

      assert get_in(thrash_budget(next_state), ["issue-1", :count]) == 1
      assert get_in(thrash_budget(next_state), ["issue-1", :window_start_ms]) == 61_000
    end

    test "accumulates count within the same window" do
      state = %State{
        dispatch_recovery: dispatch_recovery(%{"issue-1" => %{window_start_ms: 0, count: 2}})
      }

      assert {:ok, next_state} = Dispatcher.check_thrash_budget(state, "issue-1", 1_000)
      assert get_in(thrash_budget(next_state), ["issue-1", :count]) == 3
    end
  end

  describe "reset_thrash_budget/2" do
    test "removes the entry for the given issue_id" do
      state = %State{
        dispatch_recovery:
          dispatch_recovery(%{
            "issue-1" => %{window_start_ms: 0, count: 5},
            "issue-2" => %{window_start_ms: 0, count: 1}
          })
      }

      result = Dispatcher.reset_thrash_budget(state, "issue-1")

      refute Map.has_key?(thrash_budget(result), "issue-1")
      assert Map.has_key?(thrash_budget(result), "issue-2")
    end
  end

  describe "dispatch attempt provenance" do
    test "carries the current fallback fence rather than a stale redispatch snapshot" do
      issue = %Issue{id: "fallback-retry", identifier: "repo#fallback-retry", state: "todo", selected_backend: "claude"}

      current_fence = %{
        generation: 9,
        authoritative_state: "rework",
        pending_item_ids: MapSet.new([872, 874, 887, 891, 999]),
        opened_at: DateTime.utc_now()
      }

      state = %State{
        max_concurrent_agents: 1,
        effective_concurrent_agents: 1,
        running: %{
          issue.id => %{
            issue: issue,
            identifier: issue.identifier,
            control: %{status: :completed},
            lifecycle_fence: current_fence,
            redispatch_safety: %{workspace_path: "/workspaces/fallback"},
            rate_limit_fallback_replacement: true
          }
        }
      }

      next_state = Dispatcher.do_dispatch_issue(state, issue, 1, nil, runner: fn _, _, _ -> :ok end)

      assert next_state.running[issue.id].lifecycle_fence == current_fence
      assert next_state.running[issue.id].workspace_path == "/workspaces/fallback"
    end

    test "keeps local-only provider transports off configured SSH workers" do
      test_pid = self()
      write_workflow_file!(Workflow.workflow_file_path(), worker_ssh_hosts: ["worker-a"])

      issue = %Issue{
        id: "local-provider",
        identifier: "repo#local-provider",
        state: "todo",
        selected_backend: "kimi"
      }

      runner = fn dispatched_issue, recipient, opts ->
        send(test_pid, {:agent_runner_run, dispatched_issue, recipient, opts})
        :ok
      end

      next_state =
        Dispatcher.do_dispatch_issue(
          %State{max_concurrent_agents: 1, effective_concurrent_agents: 1},
          issue,
          nil,
          nil,
          runner: runner
        )

      assert_receive {:agent_runner_run, ^issue, _recipient, runner_opts}
      assert Keyword.fetch!(runner_opts, :worker_host) == nil
      assert get_in(next_state.running, [issue.id, :worker_host]) == nil
    end

    test "records the dispatch-time complexity estimate" do
      test_pid = self()

      Application.put_env(:aiur, :run_telemetry_lifecycle_recorder, fn kind, attributes, opts ->
        send(test_pid, {:lifecycle_recorded, kind, attributes, opts})
        :ok
      end)

      issue = %Issue{
        id: "complexity-dispatch",
        identifier: "repo#complexity-dispatch",
        state: "todo",
        labels: ["complexity:4"],
        selected_backend: "codex"
      }

      runner = fn dispatched_issue, recipient, opts ->
        send(test_pid, {:agent_runner_run, dispatched_issue, recipient, opts})
        :ok
      end

      Dispatcher.do_dispatch_issue(
        %State{max_concurrent_agents: 1, effective_concurrent_agents: 1},
        issue,
        nil,
        nil,
        runner: runner
      )

      assert_receive {:lifecycle_recorded, :lifecycle, attributes, _opts}
      assert attributes.event == "dispatch"
      assert attributes.complexity == 4
    end

    test "consumes the ownership wakeup envelope when redispatching" do
      issue = %Issue{id: "ownership-envelope", identifier: "repo#ownership-envelope", state: "todo", selected_backend: "codex"}
      test_pid = self()
      write_workflow_file!(Workflow.workflow_file_path(), worker_ssh_hosts: ["worker-a"])

      runner = fn dispatched_issue, recipient, opts ->
        send(test_pid, {:agent_runner_run, dispatched_issue, recipient, opts})
        :ok
      end

      state = %State{
        max_concurrent_agents: 1,
        effective_concurrent_agents: 1,
        dispatch_recovery: %{
          workspace_ownership: %{
            waits: %{},
            ready: %{
              issue.id => %{
                issue_id: issue.id,
                worker_host: "worker-a",
                retry_attempt: 3,
                prior_work: true,
                tracker_identity: "repo#ownership-envelope"
              }
            }
          },
          codex_thrash_budget: %{}
        }
      }

      next_state = Dispatcher.do_dispatch_issue(state, issue, nil, nil, runner: runner)

      assert_receive {:agent_runner_run, ^issue, _recipient, runner_opts}
      assert Keyword.fetch!(runner_opts, :worker_host) == "worker-a"
      assert Keyword.fetch!(runner_opts, :attempt) == 3
      assert Keyword.fetch!(runner_opts, :prior_work) == true
      assert next_state.dispatch_recovery.workspace_ownership.ready == %{}
    end

    test "telemetry-disabled dispatch options reach accepted Decision provenance" do
      identifier = "dispatcher-decision-#{System.unique_integer([:positive])}"
      issue = %Issue{id: identifier, identifier: identifier, state: "todo", selected_backend: "codex"}
      test_pid = self()

      enabled_key = {Aiur.RunTelemetry, :telemetry_enabled}
      original_pt = :persistent_term.get(enabled_key, :unset)

      on_exit(fn ->
        case original_pt do
          :unset -> :persistent_term.erase(enabled_key)
          value -> :persistent_term.put(enabled_key, value)
        end
      end)

      :persistent_term.put(enabled_key, false)
      refute TelemetryLifecycle.enabled?()

      runner = fn dispatched_issue, recipient, opts ->
        send(test_pid, {:agent_runner_run, dispatched_issue, recipient, opts})
        :ok
      end

      state = %State{max_concurrent_agents: 1, effective_concurrent_agents: 1}

      next_state = Dispatcher.do_dispatch_issue(state, issue, nil, nil, runner: runner)

      assert_receive {:agent_runner_run, ^issue, _recipient, runner_opts}
      assert attempt_id = Keyword.fetch!(runner_opts, :telemetry_attempt_id)
      assert is_binary(attempt_id)
      assert get_in(next_state.running, [issue.id, :telemetry_attempt_id]) == attempt_id

      start_fun = fn _workspace, _opts -> {:ok, %{model: "gpt-5.6-terra", thread_id: "thread-dispatch"}} end

      {_session_backend, _remote_control?, session_opts} =
        SessionLifecycle.resolve_session_options(issue, runner_opts, nil)

      assert Keyword.fetch!(session_opts, :attempt_id) == attempt_id

      assert {:ok, session} =
               SessionLifecycle.start_agent_session(
                 "/ws",
                 session_opts,
                 start_fun
               )

      executor = ToolExecutor.build(issue, nil, nil, session)

      assert executor.("emit_event", %{
               "name" => "decision.requested",
               "message" => "Keep the dispatch attempt?",
               "payload" => %{"blocking" => true}
             })["success"] == true

      [decision] = Aiur.DecisionStore.list() |> Enum.filter(&(&1.ticket.identifier == identifier))
      assert decision.provenance.attempt_id == attempt_id
    end

    test "identifier-less dispatch hashes the stable issue ID for its attempt identity" do
      issue_id = "memory-dispatch-#{System.unique_integer([:positive])}"
      issue = %Issue{id: issue_id, identifier: nil, state: "todo", selected_backend: "codex"}
      test_pid = self()

      enabled_key = {Aiur.RunTelemetry, :telemetry_enabled}
      original_pt = :persistent_term.get(enabled_key, :unset)

      on_exit(fn ->
        case original_pt do
          :unset -> :persistent_term.erase(enabled_key)
          value -> :persistent_term.put(enabled_key, value)
        end
      end)

      :persistent_term.put(enabled_key, false)
      refute TelemetryLifecycle.enabled?()

      runner = fn dispatched_issue, recipient, opts ->
        send(test_pid, {:agent_runner_run, dispatched_issue, recipient, opts})
        :ok
      end

      state = %State{max_concurrent_agents: 1, effective_concurrent_agents: 1}

      next_state = Dispatcher.do_dispatch_issue(state, issue, nil, nil, runner: runner)

      assert_receive {:agent_runner_run, ^issue, _recipient, runner_opts}
      assert attempt_id = Keyword.fetch!(runner_opts, :telemetry_attempt_id)
      expected_ticket = "ticket-" <> (:crypto.hash(:sha256, issue_id) |> Base.encode16(case: :lower))

      assert String.starts_with?(attempt_id, "#{expected_ticket}:")
      refute String.contains?(attempt_id, issue_id)
      assert get_in(next_state.running, [issue.id, :telemetry_attempt_id]) == attempt_id
    end

    test "unsafe, empty, and overlong tracker identifiers reach durable Decision provenance" do
      cases = [
        {"unsafe", "repo#1 ticket/123"},
        {"empty", ""},
        {"overlong", String.duplicate("tracker-identifier-", 20)}
      ]

      attempt_tickets =
        Enum.map(cases, fn {label, identifier} ->
          issue_id = "memory-#{label}-#{System.unique_integer([:positive])}"
          issue = %Issue{id: issue_id, identifier: identifier, state: "todo", selected_backend: "codex"}

          {attempt_id, decision} = dispatch_decision!(issue)
          dispatch_identity = if identifier == "", do: issue_id, else: identifier
          expected_ticket = "ticket-" <> (:crypto.hash(:sha256, dispatch_identity) |> Base.encode16(case: :lower))

          assert decision.provenance.attempt_id == attempt_id
          assert byte_size(attempt_id) <= 256
          assert [^expected_ticket, suffix] = String.split(attempt_id, ":", parts: 2)
          assert suffix =~ ~r/\A[A-Za-z0-9_-]+\z/

          if identifier != "", do: refute(String.contains?(attempt_id, identifier))

          expected_ticket
        end)

      assert length(Enum.uniq(attempt_tickets)) == length(attempt_tickets)
    end
  end

  describe "redispatch_ready?/4" do
    test "treats the current issue's worker slot as a transferable reservation" do
      write_workflow_file!(Workflow.workflow_file_path(),
        worker_ssh_hosts: ["worker-a"],
        worker_max_concurrent_agents_per_host: 1
      )

      issue = %Issue{id: "issue-1", identifier: "repo#1", selected_backend: "claude"}

      state = %State{
        running: %{
          issue.id => %{
            issue: issue,
            worker_host: "worker-a",
            control: %{status: :working}
          }
        }
      }

      assert :ok = Dispatcher.redispatch_ready?(state, issue, "worker-a", now_ms: 1_000)
      assert thrash_budget(state) == %{}
    end

    test "rejects a swap before teardown when the next restart would trip thrash protection" do
      issue = %Issue{id: "issue-1", identifier: "repo#1", selected_backend: "claude"}

      state = %State{
        dispatch_recovery: dispatch_recovery(%{issue.id => %{window_start_ms: 0, count: 6}})
      }

      assert {:error, :thrash_circuit_open} =
               Dispatcher.redispatch_ready?(state, issue, nil, now_ms: 1_000)

      assert get_in(thrash_budget(state), [issue.id, :count]) == 6
    end

    test "does not silently migrate a remote workspace when its worker is unavailable" do
      write_workflow_file!(Workflow.workflow_file_path(),
        worker_ssh_hosts: ["worker-a"],
        worker_max_concurrent_agents_per_host: 1
      )

      issue = %Issue{id: "issue-1", identifier: "repo#1", selected_backend: "claude"}

      assert {:error, :preferred_worker_unavailable} =
               Dispatcher.redispatch_ready?(%State{}, issue, "worker-b", now_ms: 1_000)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, value), do: Application.put_env(:aiur, key, value)

  # Points the workflow config at a prewarm-enabled file for the duration of a
  # test. No `base_build` and a memory tracker keep RepoBase's own resolve/poll
  # inert while `Config.prewarm_enabled?/0` reads true.
  defp with_prewarm_enabled_config do
    tmp = Path.join(System.tmp_dir!(), "dispatcher_prewarm_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    cfg = Path.join(tmp, "config")
    File.write!(cfg, "tracker:\n  kind: memory\nprewarm:\n  enabled: true\n  poll_seconds: 0\n")
    previous = Application.get_env(:aiur, :workflow_file_path)
    Aiur.Workflow.set_workflow_file_path(cfg)

    on_exit(fn ->
      case previous do
        nil -> Aiur.Workflow.clear_workflow_file_path()
        path -> Aiur.Workflow.set_workflow_file_path(path)
      end
    end)

    :ok
  end

  defp consume_available_slots(state, issues) do
    Enum.reduce(issues, state, fn issue, acc ->
      if DispatchPolicy.should_dispatch_issue?(issue, acc) do
        %{acc | running: Map.put(acc.running, issue.id, running_entry(issue.id))}
      else
        acc
      end
    end)
  end

  defp issue(id), do: %Issue{id: id, identifier: "repo##{id}", title: id, state: "todo"}

  defp dispatch_decision!(issue) do
    test_pid = self()

    runner = fn dispatched_issue, recipient, opts ->
      send(test_pid, {:agent_runner_run, dispatched_issue, recipient, opts})
      :ok
    end

    next_state =
      Dispatcher.do_dispatch_issue(
        %State{max_concurrent_agents: 1, effective_concurrent_agents: 1},
        issue,
        nil,
        nil,
        runner: runner
      )

    assert_receive {:agent_runner_run, ^issue, _recipient, runner_opts}
    attempt_id = Keyword.fetch!(runner_opts, :telemetry_attempt_id)
    assert get_in(next_state.running, [issue.id, :telemetry_attempt_id]) == attempt_id

    {_session_backend, _remote_control?, session_opts} =
      SessionLifecycle.resolve_session_options(issue, runner_opts, nil)

    assert {:ok, session} =
             SessionLifecycle.start_agent_session(
               "/ws",
               session_opts,
               fn _workspace, _opts -> {:ok, %{model: "gpt-5.6-terra", thread_id: "thread-dispatch"}} end
             )

    executor = ToolExecutor.build(issue, nil, nil, session)

    assert executor.("emit_event", %{
             "name" => "decision.requested",
             "message" => "Keep the dispatch attempt?",
             "payload" => %{"blocking" => true}
           })["success"] == true

    [decision] = Aiur.DecisionStore.list() |> Enum.filter(&(&1.ticket.identifier == issue.id))
    {attempt_id, decision}
  end

  defp running_entry(id) do
    %{issue: issue(id), control: %{status: :working}, worker_host: nil}
  end

  describe "revalidate_issue_for_dispatch/3" do
    test "returns :ok when issue is found and passes the retry candidate check" do
      issue = %Issue{id: "id-1", identifier: "repo#1", title: "Work", state: "todo"}
      terminal_states = MapSet.new(["done"])
      fetcher = fn _ids -> {:ok, [issue]} end

      assert {:ok, ^issue} =
               Dispatcher.revalidate_issue_for_dispatch(issue, fetcher, terminal_states)
    end

    test "returns {:skip, :missing} when the fetcher returns an empty list" do
      issue = %Issue{id: "id-1", identifier: "repo#1", title: "Work", state: "todo"}
      terminal_states = MapSet.new(["done"])
      fetcher = fn _ids -> {:ok, []} end

      assert {:skip, :missing} =
               Dispatcher.revalidate_issue_for_dispatch(issue, fetcher, terminal_states)
    end

    test "returns {:skip, issue} when the issue is in a terminal state" do
      issue = %Issue{id: "id-1", identifier: "repo#1", title: "Work", state: "done"}
      terminal_states = MapSet.new(["done"])
      fetcher = fn _ids -> {:ok, [issue]} end

      assert {:skip, ^issue} =
               Dispatcher.revalidate_issue_for_dispatch(issue, fetcher, terminal_states)
    end

    test "returns {:error, reason} when the fetcher fails" do
      issue = %Issue{id: "id-1", identifier: "repo#1", title: "Work", state: "todo"}
      terminal_states = MapSet.new(["done"])
      fetcher = fn _ids -> {:error, :network_error} end

      assert {:error, :network_error} =
               Dispatcher.revalidate_issue_for_dispatch(issue, fetcher, terminal_states)
    end

    test "passes through non-Issue values unchanged" do
      assert {:ok, :not_an_issue} =
               Dispatcher.revalidate_issue_for_dispatch(:not_an_issue, nil, nil)
    end
  end
end
