defmodule Aiur.Orchestrator.Dispatcher.PrewarmHoldObservabilityTest do
  use Aiur.DispatcherTestSupport

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

    test "records ready-work prewarm samples for fleet starvation detection" do
      with_prewarm_enabled_config()

      ready = Enum.map(1..8, &issue("prewarm-fleet-#{&1}"))

      admission_probes = fn ->
        %{
          memory_mb: 4_000,
          memory_threshold_mb: 2_048,
          fd_sample: :unavailable,
          runnable: :unavailable,
          run_queue_threshold: nil,
          schedulers: 16,
          load: 0.7,
          load_threshold: 1.0,
          build_status: %{enabled?: false, capacity: 0, active: 0, queued: 0},
          provider_backends: [],
          cpu_snapshot: :unavailable,
          target: 1.0
        }
      end

      state = %State{
        max_concurrent_agents: 20,
        effective_concurrent_agents: 20,
        running: Map.new(1..3, fn id -> {"live-#{id}", running_entry("live-#{id}")} end)
      }

      held =
        Dispatcher.dispatch_or_hold(state, ready, fn -> :building end, admission_probes_fun: admission_probes)

      assert %{load: 0.7, gate_signal: 0.7, load_threshold: 1.0, target: 1.0, schedulers: 16} = held.dispatch_capacity_sample

      waiting = IssueSync.sync_fleet_capacity_starved_alert(held, ready, 1_000)
      assert waiting.fleet_capacity_starvation.since_ms == 1_000
    end

    test "prewarm sampling keeps ready-transition CPU corroboration fresh" do
      with_prewarm_enabled_config()

      ready = [issue("prewarm-cpu-window")]
      previous_cpu = %{total: 900, idle: 400, nice: 0, runnable: 2}
      prewarm_cpu = %{total: 1_100, idle: 580, nice: 0, runnable: 2}
      ready_cpu = %{total: 1_200, idle: 590, nice: 0, runnable: 20}

      probes = fn cpu_snapshot ->
        %{
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
          cpu_snapshot: cpu_snapshot,
          target: nil
        }
      end

      state = %State{
        max_concurrent_agents: 8,
        effective_concurrent_agents: 8,
        load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: previous_cpu, bootstrap_complete?: true}
      }

      held =
        Dispatcher.dispatch_or_hold(state, ready, fn -> :building end, admission_probes_fun: fn -> probes.(prewarm_cpu) end)

      assert held.load_envelope_state.cpu_snapshot == prewarm_cpu

      ready_state =
        Dispatcher.dispatch_or_hold(held, ready, fn -> :ready end, admission_probes_fun: fn -> probes.(ready_cpu) end)

      assert %{signal: :load, reclaimable_cpu_percent: 10.0} = ready_state.capacity_hold
      assert map_size(ready_state.running) == 0
    end

    # The reported binding is read from the daemon's persisted `capacity_hold`,
    # and before #2527 the prewarm branch sampled host pressure without ever
    # reconciling it. A base build that runs for minutes therefore froze the
    # last pre-build measurement: `status` reported `load=24.14` against a
    # `threshold=24.0` for the build's whole duration while the live `LOAD` line
    # beside it read 6-7. The recovery direction is the whole defect, so the
    # sequence here is high-then-low; a one-directional test passes against the
    # bug.
    test "a prewarm hold re-samples host pressure so a high load figure cannot latch" do
      with_prewarm_enabled_config()

      ready = [issue("prewarm-stale-load")]

      # 45% reclaimable in both windows: only the load average moves, so the
      # recovery is attributable to the re-sample and not to CPU corroboration
      # incidentally clearing the gate.
      first_cpu = %{total: 1_100, idle: 545, nice: 0, runnable: 2}
      second_cpu = %{total: 1_200, idle: 590, nice: 0, runnable: 2}

      quiet = [emit_fun: fn _name, _reason -> :ok end, telemetry_fun: fn _event, _payload -> :ok end]

      # The high sample is taken on a normal dispatch tick, before the base build
      # starts — the hold this leaves behind is the one that used to latch.
      held =
        Dispatcher.maybe_choose_under_load(
          contended_state(%{total: 1_000, idle: 500, nice: 0, runnable: 2}),
          ready,
          fn admitted, _issues -> admitted end,
          [admission_probes_fun: contended_probes(24.14, first_cpu), now_ms: 0] ++ quiet
        )

      assert %{signal: :load, measured: 24.14, threshold: 24.0, reclaimable_cpu_percent: 45.0} = held.capacity_hold
      assert %DateTime{} = held.capacity_hold.measured_at

      # Same prewarm hold, next tick, host now idle. The build is still running,
      # so nothing external clears the gate — only the re-sample can.
      recovered =
        Dispatcher.dispatch_or_hold(
          contended_state(first_cpu, held),
          ready,
          fn -> :building end,
          [admission_probes_fun: contended_probes(6.34, second_cpu), now_ms: 1_000] ++ quiet
        )

      assert recovered.capacity_hold == nil
    end

    # The measurement and the hold's own age are different quantities. An
    # extended hold must carry this tick's probe, or the age reported beside it
    # describes how long the fleet has been held rather than how fresh the
    # number is.
    test "an extended admission hold carries the newest measurement and stamp" do
      first_at = ~U[2026-09-02 22:00:00Z]
      later_at = ~U[2026-09-02 22:00:30Z]

      quiet = [emit_fun: fn _name, _reason -> :ok end, telemetry_fun: fn _event, _payload -> :ok end]

      state =
        contended_state(%{total: 1_000, idle: 500, nice: 0, runnable: 2})

      held =
        Dispatcher.maybe_choose_under_load(
          state,
          [issue("hold-restamp")],
          fn admitted, _issues -> admitted end,
          [
            admission_probes_fun: contended_probes(30.0, %{total: 1_100, idle: 545, nice: 0, runnable: 2}),
            now_ms: 0,
            utc_now_fun: fn -> first_at end
          ] ++ quiet
        )

      assert %{measured: 30.0, measured_at: ^first_at} = held.capacity_hold

      extended =
        Dispatcher.maybe_choose_under_load(
          contended_state(%{total: 1_100, idle: 545, nice: 0, runnable: 2}, held),
          [issue("hold-restamp")],
          fn admitted, _issues -> admitted end,
          [
            admission_probes_fun: contended_probes(27.0, %{total: 1_200, idle: 590, nice: 0, runnable: 2}),
            now_ms: 1_000,
            utc_now_fun: fn -> later_at end
          ] ++ quiet
        )

      assert %{measured: 27.0, measured_at: ^later_at} = extended.capacity_hold
      assert extended.capacity_hold.held_since_ms == 0
    end

    # The admission direction of the same recovery: a high sample must not keep
    # new work out once the host has quietened.
    test "a low sample after a high one admits new work" do
      quiet = [emit_fun: fn _name, _reason -> :ok end, telemetry_fun: fn _event, _payload -> :ok end]

      test_pid = self()

      choose = fn admitted, _issues ->
        send(test_pid, :admitted)
        admitted
      end

      held =
        Dispatcher.maybe_choose_under_load(
          contended_state(%{total: 1_000, idle: 500, nice: 0, runnable: 2}),
          [issue("admission-recovery")],
          choose,
          [
            admission_probes_fun: contended_probes(24.14, %{total: 1_100, idle: 545, nice: 0, runnable: 2}),
            now_ms: 0
          ] ++ quiet
        )

      assert %{signal: :load, measured: 24.14} = held.capacity_hold
      refute_received :admitted

      admitted =
        Dispatcher.maybe_choose_under_load(
          contended_state(%{total: 1_100, idle: 545, nice: 0, runnable: 2}, held),
          [issue("admission-recovery")],
          choose,
          [
            admission_probes_fun: contended_probes(6.34, %{total: 1_200, idle: 590, nice: 0, runnable: 2}),
            now_ms: 1_000
          ] ++ quiet
        )

      assert admitted.capacity_hold == nil
      assert_received :admitted
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

  # Future regression guard: prewarm already records the known gate before
  # DispatchOutcome runs, including the repo-base freshness probe (:checking).
  test "prewarm and repo-base hold phases preserve their known cause in empty dispatch outcomes" do
    with_prewarm_enabled_config()
    ready = issue("known-prewarm-hold")
    state = %State{max_concurrent_agents: 12, effective_concurrent_agents: 12, blocked_ticket_ids: MapSet.new()}
    owner = self()

    for phase <- [:cloning, :fetching, :building, :checking] do
      held =
        Dispatcher.dispatch_or_hold(state, [ready], fn -> phase end,
          admission_probes_fun: contended_probes(0.0, :unavailable),
          log_fun: &send(owner, {:hold_log, &1})
        )

      assert held.running == %{}
      assert Slots.available_slots(held) == 12
      assert held.dispatch_selection_hold.reasons == [:build]
      assert %{kind: :build, detail: "prewarm=#{phase}"} in held.dispatch_capacity_constraints
      assert_receive {:hold_log, prewarm_log}, 1_000
      assert prewarm_log =~ "phase=#{inspect(phase)}"
      assert_receive {:hold_log, outcome_log}, 1_000
      assert outcome_log =~ "reasons: [:build]"
      refute outcome_log =~ "unknown"
    end
  end

  test "tracker preflight skips dispatch with free slots and names its reason in status" do
    ready = issue("preflight-empty")
    state = %State{max_concurrent_agents: 12, effective_concurrent_agents: 12, last_polled_issues: %{ready.id => ready}, blocked_ticket_ids: MapSet.new()}
    owner = self()
    hold = %{reason: :shared_budget, resource: "core", reset_at: DateTime.add(DateTime.utc_now(), 60)}
    reason = {:github_auth_preflight_failed, %{reason: :local_hold, classification: :local_hold, detail: %{hold: hold}, request_error: inspect({:aiur, :locally_held, hold})}}

    held =
      Dispatcher.maybe_dispatch(
        state,
        fn state ->
          send(owner, :dispatch_attempted)
          state
        end,
        fn state -> {:error, reason, state} end
      )

    refute_received :dispatch_attempted
    capacity = held |> StatusReport.snapshot_input() |> StatusReport.snapshot_payload() |> Map.fetch!(:capacity)
    assert capacity.available == 12
    assert capacity.queued_demand? == true

    assert {:tracker_preflight, %{detail: "shared_budget (core)"}} =
             CapacityBinding.binding(capacity)

    assert {:tracker_preflight, %{detail: "shared_budget (core)"}} =
             CapacityBinding.binding(%{capacity | queued_demand?: false}, %{tracker_snapshot_fresh?: true})

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Aiur.AgentControlCLI.status(fleet_view: {:ok, %{capacity: capacity, statuses: [], global_pause: %{globally_paused: false}}, %{status: :fresh}})
      end)

    assert output =~ ~r/binding: tracker preflight, reason=shared_budget \(core\) held=\d+s/
    assert CapacityBinding.short_label(CapacityBinding.binding(capacity)) =~ ~r/held=\d+s/
    assert Slots.dispatch_hold_status(held, held.dispatch_hold.held_since_ms + 90_000).held_for_seconds == 90
  end

  test "an empty dispatch cycle with ready work names revalidation failure in capacity status" do
    with_prewarm_enabled_config()
    Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)
    Application.put_env(:aiur, :file_descriptor_sample_override, fn -> :unavailable end)
    ready = issue("empty-selection")
    state = %State{max_concurrent_agents: 12, effective_concurrent_agents: 12, blocked_ticket_ids: MapSet.new()}

    declined =
      Dispatcher.dispatch_or_hold(state, [ready], fn -> :ready end,
        issue_fetcher: fn _ -> {:error, :transport_unavailable} end,
        blocked_by_hydrator: fn issue -> {:ok, issue} end
      )

    assert map_size(declined.running) == 0
    assert Slots.available_slots(declined) > 0
    capacity = declined |> StatusReport.snapshot_input() |> StatusReport.snapshot_payload() |> Map.fetch!(:capacity)

    assert {:dispatch_selection, %{reasons: [:tracker_revalidation_failed], candidates: 1}} =
             CapacityBinding.binding(capacity)

    assert CapacityBinding.short_label(CapacityBinding.binding(capacity)) =~ "tracker_revalidation_failed"

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Aiur.AgentControlCLI.status(fleet_view: {:ok, %{capacity: capacity, statuses: [], global_pause: %{globally_paused: false}}, %{status: :fresh}})
      end)

    assert output =~ "binding: dispatch selection, reasons=[:tracker_revalidation_failed] candidates=1"
    assert output =~ ~r/sampled=\d+s ago/

    cleared = Dispatcher.dispatch_or_hold(declined, [], fn -> :ready end)
    assert cleared.dispatch_selection_hold == nil

    dispatched =
      Dispatcher.dispatch_or_hold(declined, [ready], fn -> :ready end,
        issue_fetcher: fn _ -> {:ok, [ready]} end,
        blocked_by_hydrator: fn issue -> {:ok, issue} end,
        runner: fn _issue, _recipient, _opts -> :ok end
      )

    assert Map.has_key?(dispatched.running, ready.id)
    assert Slots.available_slots(dispatched) > 0
    assert dispatched.dispatch_selection_hold == nil
  end
end
