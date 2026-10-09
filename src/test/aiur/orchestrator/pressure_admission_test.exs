defmodule Aiur.Orchestrator.PressureAdmissionTest do
  use Aiur.TestSupport
  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.{Issue, SystemPressure, Workflow}
  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, IssueSync, PressureAdmission, Slots, State}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      max_concurrent_agents: 20,
      max_cpu_pressure: 20.0,
      target_cpu_pressure: 10.0,
      load_ramp_step: 1,
      load_cooldown_seconds: 60,
      min_free_memory_mb: 4096
    )

    :ok
  end

  test "high D-state load and four busy builds do not hold a low-pressure fleet" do
    state = %State{max_concurrent_agents: 20, effective_concurrent_agents: 20}
    probes = probes(2.65)
    sampled = dispatch(state, probes, 60_000)
    assert sampled.capacity_hold == nil
    assert sampled.effective_concurrent_agents == 20
    assert Enum.any?(sampled.running, fn {id, _} -> id == "selected" end)
    refute Enum.any?(sampled.dispatch_capacity_constraints, &(&1.kind in [:load, :run_queue, :build_queue]))
  end

  test "normal dispatch selection admits the configured 20 model-waiting agents" do
    issues = for id <- 1..25, do: %Issue{id: "#{id}", identifier: "repo##{id}", title: "waiting", state: "todo"}

    select = fn state, tickets ->
      Enum.reduce(tickets, state, fn ticket, current ->
        if DispatchPolicy.should_dispatch_issue?(ticket, current),
          do: %{current | running: Map.put(current.running, ticket.id, %{issue: ticket, control: %{status: :working}, worker_host: nil})},
          else: current
      end)
    end

    now = 60_000

    sampled =
      Dispatcher.maybe_choose_under_load(%State{max_concurrent_agents: 20, effective_concurrent_agents: 20}, issues, select,
        now_ms: now,
        admission_probes_fun: fn -> Map.merge(probes(2.65), %{sampled_at_ms: now, sample_id: now}) end
      )

    assert map_size(sampled.running) == 20
    assert Slots.available_slots(sampled) == 0
  end

  test "CPU pressure holds immediately with exact percent threshold and memory takes precedence" do
    probes = probes(20.01)
    assert {:hold, %{signal: :cpu_pressure, measured: 20.01, threshold: 20.0}} = DispatchPolicy.admission_gate(probes)
    assert :dispatch = DispatchPolicy.admission_gate(probes(20.0))
    assert {:hold, %{signal: :memory, measured: 4095, threshold: 4096}} = DispatchPolicy.admission_gate(%{probes | memory_mb: 4095})
    sampled = dispatch(%State{max_concurrent_agents: 20, effective_concurrent_agents: 20}, probes, 60_000)
    assert sampled.running == %{}
    assert %{signal: :cpu_pressure, measured: 20.01, threshold: 20.0} = sampled.capacity_hold
    assert Enum.any?(sampled.dispatch_capacity_constraints, &(&1.kind == :cpu_pressure))
    assert Slots.max_concurrent_agent_status(sampled).cpu_pressure == %{avg10: 20.01, avg60: 20.01}
  end

  test "real probe wiring and auto-resume use PSI, then explicitly fall back when PSI disappears" do
    Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "99.0 99.0 99.0 1/1 1"} end)
    Application.put_env(:aiur, :cpu_pressure_source_override, fn -> {:ok, "some avg10=95 avg60=2.65 avg300=1 total=1"} end)
    Application.put_env(:aiur, :meminfo_source_override, fn -> {:ok, "MemAvailable: 8388608 kB\n"} end)
    Application.put_env(:aiur, :build_gate_status_override, fn -> %{enabled?: true, capacity: 4, active: 4, queued: 2} end)
    sample = PressureAdmission.sample()
    assert sample.cpu_pressure == SystemPressure.cpu()
    assert sample.target == nil
    assert sample.load_threshold == nil
    assert sample.run_queue_threshold == nil
    state = %State{max_concurrent_agents: 20, effective_concurrent_agents: 20}
    assert Dispatcher.auto_resume_admission(state) == :dispatch
    Application.put_env(:aiur, :cpu_pressure_source_override, fn -> {:ok, "some avg10=95 avg60=21 avg300=1 total=1"} end)
    assert Dispatcher.auto_resume_admission(state) == {:hold, :cpu_pressure}
    Application.put_env(:aiur, :cpu_pressure_source_override, fn -> {:error, :enoent} end)
    assert PressureAdmission.sample().load_threshold == 1.5
    assert Dispatcher.auto_resume_admission(state) == {:hold, :load}
  end

  test "AIMD ramps to 20 under low PSI despite high load and occupied builds" do
    state = %State{max_concurrent_agents: 20, effective_concurrent_agents: 1}
    states = Enum.scan(1..20, state, fn id, current -> update(current, 2.65, id * 60_000) end)
    assert Enum.map(states, & &1.effective_concurrent_agents) == Enum.to_list(2..20) ++ [20]
  end

  test "AIMD rejects short bursts, decreases sustained pressure with cooldown, and uses a recovery band" do
    state = %State{max_concurrent_agents: 20, effective_concurrent_agents: 20}
    states = Enum.scan(Enum.with_index([11.0, 11.0, 8.0, 11.0, 11.0, 11.0, 11.0, 11.0]), state, fn {pressure, index}, current -> update(current, pressure, (index + 1) * 30_000) end)
    assert Enum.map(states, & &1.effective_concurrent_agents) == [20, 20, 20, 20, 20, 10, 10, 5]
    decreased = List.last(states)
    for pressure <- [8.0, 9.99, 10.0], do: assert(update(decreased, pressure, 300_000).effective_concurrent_agents == 5)
    assert update(decreased, 7.99, 300_000).effective_concurrent_agents == 6
    assert PressureAdmission.update(decreased, probes(2.0), 300_000, true, false).effective_concurrent_agents == 5
    disabled = PressureAdmission.update(decreased, %{probes(99.0) | pressure_target: nil}, 300_000, true, true)
    assert disabled.effective_concurrent_agents == 20
  end

  test "switching between PSI and fallback never combines overload streaks" do
    state = %State{max_concurrent_agents: 20, effective_concurrent_agents: 20}
    two = state |> update(11.0, 60_000) |> update(11.0, 120_000)
    fallback = %{probes(11.0) | cpu_pressure: :unavailable, target: 1.0}
    switched = PressureAdmission.update(two, fallback, 180_000, true, true)
    assert switched.effective_concurrent_agents == 20
    assert switched.load_envelope_state.overload_samples == 1
    restored = update(switched, 11.0, 240_000)
    assert restored.effective_concurrent_agents == 20
    assert restored.load_envelope_state.overload_samples == 1
  end

  test "fleet alerts report PSI, and low-pressure recovery is not mistaken for starvation" do
    Publisher.set_tracked_fn(fn _ -> true end)
    :ok = Exchange.subscribe("system.fleet.capacity.starved")
    ready = [%Issue{id: "ready", identifier: "repo#ready", title: "ready", state: "todo"}]
    state = dispatch(%State{poll_interval_ms: 5_000, max_concurrent_agents: 20, effective_concurrent_agents: 5}, probes(25.0), 60_000)
    waiting = IssueSync.sync_fleet_capacity_starved_alert(state, ready, 1_000)
    alerted = IssueSync.sync_fleet_capacity_starved_alert(waiting, ready, 6_000)
    assert alerted.fleet_capacity_starvation.alert_active
    assert_received {:event, %{topic: "system.fleet.capacity.starved"} = event}
    assert event["reason"] =~ "CPU PSI some avg60 (%)=25.0/10.0"
    assert event["reason"] =~ "binding constraint=CPU PSI gate"

    recovered = %{
      state
      | capacity_hold: nil,
        dispatch_capacity_constraints: [],
        dispatch_capacity_sample: probes(2.0),
        running: Map.new(1..5, fn id -> {"active#{id}", %{control: %{status: :working}}} end)
    }

    quiet = IssueSync.sync_fleet_capacity_starved_alert(recovered, ready, 1_000)
    assert quiet.fleet_capacity_starvation.since_ms == nil
  end

  defp update(state, pressure, now), do: PressureAdmission.update(state, probes(pressure), now, true, true)

  defp dispatch(state, probes, now) do
    Dispatcher.maybe_choose_under_load(state, [], fn current, _ -> %{current | running: %{"selected" => %{}}} end,
      now_ms: now,
      admission_probes_fun: fn -> Map.merge(probes, %{sampled_at_ms: now, sample_id: now}) end
    )
  end

  defp probes(pressure) do
    %{
      cpu_pressure: %{avg10: pressure, avg60: pressure},
      pressure_threshold: 20.0,
      pressure_target: 10.0,
      memory_mb: 8192,
      memory_threshold_mb: 4096,
      fd_sample: :unavailable,
      runnable: 99,
      run_queue_threshold: 1.0,
      schedulers: 16,
      load: 99.0,
      load_threshold: 1.5,
      target: nil,
      cpu_snapshot: :unavailable,
      cpu_headroom: :unavailable,
      build_status: %{enabled?: true, capacity: 4, active: 4, queued: 10},
      provider_backends: [],
      queued_demand?: true
    }
  end
end
