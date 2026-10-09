defmodule Aiur.Orchestrator.PriorityLoadTest do
  use Aiur.TestSupport
  import ExUnit.CaptureIO

  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, Slots, State}
  alias Aiur.SystemLoad

  test "niced demand below the reclaimable cutoff admits while normal priority holds" do
    niced = %{idle_percent: 0.0, nice_percent: 59.4, reclaimable_percent: 59.4}
    normal = %{idle_percent: 0.0, nice_percent: 0.0, reclaimable_percent: 0.0}

    # All-niced CPU already passed the corroboration gate; preserve that behavior.
    assert DispatchPolicy.load_admission_reason(25.66, 1.5, 16, %{niced | nice_percent: 100.0, reclaimable_percent: 100.0}) == :dispatch
    assert DispatchPolicy.load_admission_reason(25.66, 1.5, 16, niced) == :dispatch
    assert {:hold, %{signal: :load, measured: 25.66, threshold: 24.0}} = DispatchPolicy.load_admission_reason(25.66, 1.5, 16, normal)
    assert DispatchPolicy.run_queue_admission_reason(26, 16, 1.5, niced) == :dispatch
    assert {:hold, %{signal: :run_queue}} = DispatchPolicy.run_queue_admission_reason(26, 16, 1.5, normal)
  end

  test "adaptive envelope ramps beyond three under niced load and backs off under normal load" do
    options = %{
      target: 1.0,
      schedulers: 16,
      static_limit: 12,
      ramp_step: 1,
      cooldown_ms: 0,
      now_ms: 1_000,
      queued_work?: true,
      used_slots: 3,
      cpu_headroom: %{idle_percent: 0.0, nice_percent: 59.4, reclaimable_percent: 59.4}
    }

    assert {4, nil} = DispatchPolicy.load_envelope(3, nil, 25.0, options)
    assert {2, 1_000} = DispatchPolicy.load_envelope(3, nil, 25.0, %{options | cpu_headroom: %{nice_percent: 0.0}})
  end

  test "dispatch projects total and adjusted load into status with sample age" do
    sampled_at = System.monotonic_time(:millisecond) - 5_000
    previous = %{total: 1_000, idle: 0, nice: 0, runnable: 26}
    current = %{total: 2_000, idle: 0, nice: 594, runnable: 26}
    state = %State{max_concurrent_agents: 12, effective_concurrent_agents: 3, load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: previous, bootstrap_complete?: true}}

    probes = %{
      load: 25.0,
      load_threshold: 1.5,
      target: 1.0,
      schedulers: 16,
      sampled_at_ms: sampled_at,
      sample_id: make_ref(),
      cpu_snapshot: current,
      runnable: 26,
      run_queue_threshold: 1.5,
      memory_mb: :unavailable,
      memory_threshold_mb: nil,
      fd_sample: :unavailable,
      build_status: %{enabled?: false},
      provider_backends: [],
      github_quota: :available
    }

    ready = [%Aiur.Issue{id: "priority-load", identifier: "repo#priority-load", title: "Ready", state: "todo"}]

    result =
      Dispatcher.maybe_choose_under_load(
        state,
        ready,
        fn admitted, _ ->
          send(self(), :selected)
          admitted
        end,
        admission_probes_fun: fn -> probes end,
        telemetry_fun: fn _, _ -> :ok end,
        emit_fun: fn _, _ -> :ok end
      )

    assert_received :selected
    assert result.capacity_hold == nil
    refute Enum.any?(result.dispatch_capacity_constraints, &(&1.kind == :load_envelope))
    capacity = Slots.max_concurrent_agent_status(result)
    assert capacity.load == 25.0
    assert_in_delta capacity.gate_signal, 15.496, 0.0001
    assert capacity.load_sampled_at_ms == sampled_at
    assert result.effective_concurrent_agents == 4
    output = capture_io(fn -> SystemLoad.print_dispatch_sample(capacity) end)
    assert output =~ "DISPATCH LOAD total=25.0 gate_signal=15.496"
    assert output =~ "sampled=5s ago"
  end
end
