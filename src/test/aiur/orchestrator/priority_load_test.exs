defmodule Aiur.Orchestrator.PriorityLoadTest do
  use Aiur.TestSupport
  import ExUnit.CaptureIO

  alias Aiur.{BackgroundCpu, SystemCpu, SystemLoad}
  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, Slots, State}

  # Two /proc scans 1_000 host ticks apart; `procs` maps pid => {nice, ticks_before, ticks_after}.
  defp sampled_headroom(daemon_nice, procs, aggregate_nice_delta) do
    root = Path.join(System.tmp_dir!(), "aiur-proc-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    write = fn index -> Enum.each(procs, fn {pid, {nice, before, after_}} -> write_stat(root, pid, nice, elem({before, after_}, index)) end) end

    write.(0)
    first = BackgroundCpu.advance(nil, daemon_nice, BackgroundCpu.scan(root, daemon_nice), 1_000, 0)
    write.(1)
    second = BackgroundCpu.advance(first, daemon_nice, BackgroundCpu.scan(root, daemon_nice), 2_000, 10_000)

    previous = %{total: 1_000, idle: 0, nice: 0, runnable: 26, background: first.reading}
    current = %{total: 2_000, idle: 0, nice: aggregate_nice_delta, runnable: 26, background: second.reading}
    SystemCpu.headroom(previous, current)
  end

  defp write_stat(root, pid, nice, ticks) do
    fields = List.duplicate("0", 20) |> List.replace_at(0, "R") |> List.replace_at(11, "#{ticks}") |> List.replace_at(16, "#{nice}") |> List.replace_at(19, "7")
    File.mkdir_p!(Path.join(root, "#{pid}"))
    File.write!(Path.join([root, "#{pid}", "stat"]), "#{pid} (proc) name) #{Enum.join(fields, " ")}\n")
  end

  test "(a) daemon at nice 0 discounts nice-15 background CPU but counts its nice-0 fleet" do
    headroom = sampled_headroom(0, %{101 => {0, 0, 300}, 202 => {15, 50, 644}}, 594)

    assert headroom.daemon_nice == 0
    assert_in_delta headroom.background_percent, 59.4, 0.0001
    assert_in_delta SystemLoad.gate_signal(25.0, headroom, 16), 15.496, 0.0001
    assert SystemLoad.discount_reason(headroom) == :enabled
    assert DispatchPolicy.load_admission_reason(25.66, 1.5, 16, headroom) == :dispatch
    assert DispatchPolicy.run_queue_admission_reason(26, 16, 1.5, headroom) == :dispatch
  end

  test "(b) daemon at nice 5 counts its nice-5 fleet even though /proc/stat files it as niced" do
    headroom = sampled_headroom(5, %{101 => {5, 0, 1_000}}, 1_000)

    assert headroom.nice_percent == 100.0
    assert headroom.background_percent == 0.0
    assert headroom.reclaimable_percent == 0.0
    assert SystemLoad.gate_signal(25.0, headroom, 16) == 25.0
    assert {:hold, %{signal: :load}} = DispatchPolicy.load_admission_reason(25.0, 1.5, 16, headroom)
    assert {:hold, %{signal: :run_queue}} = DispatchPolicy.run_queue_admission_reason(26, 16, 1.5, headroom)

    options = %{target: 1.0, schedulers: 16, static_limit: 12, ramp_step: 1, cooldown_ms: 0, now_ms: 1_000, queued_work?: true, used_slots: 3, cpu_headroom: headroom}
    assert {2, 1_000} = DispatchPolicy.load_envelope(3, nil, 25.0, options)

    # Work niced further than the daemon still discounts.
    lower = sampled_headroom(5, %{101 => {5, 0, 600}, 202 => {15, 0, 400}}, 1_000)
    assert_in_delta SystemLoad.gate_signal(25.0, lower, 16), 18.6, 0.0001
  end

  test "(c) unreadable /proc gives no discount and never reads as zero load" do
    missing = Path.join(System.tmp_dir!(), "aiur-proc-missing-#{System.unique_integer([:positive])}")
    assert BackgroundCpu.scan(missing, 0) == :unavailable
    unavailable = BackgroundCpu.advance(nil, 0, :unavailable, 1_000, 0)
    assert unavailable.reading == :unavailable
    assert BackgroundCpu.advance(nil, :unavailable, %{}, 1_000, 0).reading == :unavailable

    previous = %{total: 1_000, idle: 0, nice: 0, runnable: 26, background: unavailable.reading}
    headroom = SystemCpu.headroom(previous, %{previous | total: 2_000, nice: 1_000})
    options = %{target: 1.0, schedulers: 16, static_limit: 12, ramp_step: 1, cooldown_ms: 0, now_ms: 1_000, queued_work?: true, used_slots: 3, cpu_headroom: :unavailable}

    for evidence <- [headroom, :unavailable, %{}, %{background_percent: 150.0}, %{background_percent: :unavailable}] do
      assert SystemLoad.gate_signal(25.0, evidence, 16) == 25.0
      assert SystemLoad.discount_reason(evidence) == :unavailable
      assert {2, 1_000} = DispatchPolicy.load_envelope(3, nil, 25.0, %{options | cpu_headroom: evidence})
    end

    assert headroom.reclaimable_percent == 0.0
    assert {:hold, %{signal: :load}} = DispatchPolicy.load_admission_reason(25.0, 1.5, 16, headroom)

    output =
      capture_io(fn ->
        SystemLoad.print_dispatch_sample(%{load: 25.0, gate_signal: 25.0, load_discount_reason: :unavailable, load_sampled_at_ms: System.monotonic_time(:millisecond)})
      end)

    assert output =~ "gate_signal=25.0 (background CPU unavailable, no discount)"
  end

  test "a changed daemon nice or sampler epoch cannot combine readings" do
    reading = %{epoch: make_ref(), daemon_nice: 0, ticks: 0, cpu_total: 1_000, sampled_at_ms: 0}
    previous = %{total: 1_000, idle: 0, nice: 0, runnable: 26, background: reading}
    restarted = %{reading | epoch: make_ref(), ticks: 900, cpu_total: 2_000}
    headroom = SystemCpu.headroom(previous, %{previous | total: 2_000, background: restarted})
    assert headroom.background_percent == :unavailable
    assert SystemLoad.gate_signal(25.0, headroom, 16) == 25.0

    first = BackgroundCpu.advance(nil, 0, %{{"1", 7} => 10}, 1_000, 0)
    renice = BackgroundCpu.advance(first, 5, %{{"1", 7} => 900}, 2_000, 10_000)
    refute renice.reading.epoch == first.reading.epoch
    assert renice.reading.ticks == 0
  end

  test "dispatch projects total and adjusted load into status with sample age" do
    sampled_at = System.monotonic_time(:millisecond) - 5_000
    previous = %{total: 1_000, idle: 0, nice: 0, runnable: 26, background: %{epoch: :e, daemon_nice: 0, ticks: 0, cpu_total: 1_000}}
    current = %{previous | total: 2_000, nice: 594, background: %{epoch: :e, daemon_nice: 0, ticks: 594, cpu_total: 2_000}}
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
    assert output =~ "DISPATCH LOAD (fallback only when PSI unavailable) total=25.0 gate_signal=15.496 (discounts CPU niced above the daemon) daemon_nice=0"
    assert [_, age] = Regex.run(~r/sampled=(\d+)s ago/, output)
    assert String.to_integer(age) >= 5
  end
end
