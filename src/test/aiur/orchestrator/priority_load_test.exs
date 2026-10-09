defmodule Aiur.Orchestrator.PriorityLoadTest do
  use Aiur.TestSupport
  import ExUnit.CaptureIO

  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, Slots, State}
  alias Aiur.SystemLoad

  test "niced demand below the reclaimable cutoff admits while normal priority holds" do
    niced = %{daemon_nice: 0, idle_percent: 0.0, nice_percent: 59.4, reclaimable_percent: 59.4}
    normal = %{daemon_nice: 0, idle_percent: 0.0, nice_percent: 0.0, reclaimable_percent: 0.0}

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
      cpu_headroom: %{daemon_nice: 0, idle_percent: 0.0, nice_percent: 59.4, reclaimable_percent: 59.4}
    }

    assert {4, nil} = DispatchPolicy.load_envelope(3, nil, 25.0, options)
    assert {2, 1_000} = DispatchPolicy.load_envelope(3, nil, 25.0, %{options | cpu_headroom: %{nice_percent: 0.0}})
  end

  test "dispatch projects total and adjusted load into status with sample age" do
    sampled_at = System.monotonic_time(:millisecond) - 5_000
    previous = %{total: 1_000, idle: 0, nice: 0, daemon_nice: 0, runnable: 26}
    current = %{total: 2_000, idle: 0, nice: 594, daemon_nice: 0, runnable: 26}
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
    assert result.load_envelope_state.overload_samples == 0
    output = capture_io(fn -> SystemLoad.print_dispatch_sample(capacity) end)
    assert output =~ "DISPATCH LOAD total=25.0 gate_signal=15.496"
    assert [_, age] = Regex.run(~r/sampled=(\d+)s ago/, output)
    assert String.to_integer(age) >= 5
  end

  test "a niced daemon counts its fleet CPU and reports no discount" do
    previous = %{total: 1_000, idle: 0, nice: 0, daemon_nice: 5, runnable: 26}
    current = %{previous | total: 2_000, nice: 1_000}
    headroom = Aiur.SystemCpu.headroom(previous, current)
    assert headroom.nice_percent == 100.0
    assert headroom.reclaimable_percent == 0.0
    assert SystemLoad.gate_signal(25.0, headroom, 16) == 25.0
    assert {:hold, %{signal: :load}} = DispatchPolicy.load_admission_reason(25.0, 1.5, 16, headroom)
    assert SystemLoad.discount_reason(headroom) == :daemon_niced

    output =
      capture_io(fn ->
        SystemLoad.print_dispatch_sample(%{
          load: 25.0,
          gate_signal: SystemLoad.gate_signal(25.0, headroom, 16),
          load_discount_reason: SystemLoad.discount_reason(headroom),
          load_sampled_at_ms: System.monotonic_time(:millisecond)
        })
      end)

    assert output =~ "gate_signal=25.0 (daemon niced, no discount)"
  end

  test "unavailable or malformed CPU evidence cannot invent zero load or widen the envelope" do
    options = %{target: 1.0, schedulers: 16, static_limit: 12, ramp_step: 1, cooldown_ms: 0, now_ms: 1_000, queued_work?: true, used_slots: 3, cpu_headroom: :unavailable}

    for headroom <- [:unavailable, %{}, %{daemon_nice: 0, nice_percent: 150.0}, %{daemon_nice: :unavailable, nice_percent: 90.0}] do
      assert SystemLoad.gate_signal(25.0, headroom, 16) == 25.0
      assert SystemLoad.discount_reason(headroom) == :unavailable
      assert {2, 1_000} = DispatchPolicy.load_envelope(3, nil, 25.0, %{options | cpu_headroom: headroom})
    end

    output =
      capture_io(fn ->
        SystemLoad.print_dispatch_sample(%{
          load: 25.0,
          gate_signal: 25.0,
          load_discount_reason: :unavailable,
          load_sampled_at_ms: System.monotonic_time(:millisecond)
        })
      end)

    assert output =~ "gate_signal=25.0 (priority or CPU unavailable, no discount)"
  end
end
