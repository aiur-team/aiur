defmodule Aiur.Orchestrator.SustainedLoadTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy, State}
  alias Aiur.Workflow

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 16, target_load_average: 1.0, load_cooldown_seconds: 60)
    :ok
  end

  test "two-sample bursts with below-target mean preserve the ready width" do
    trace = List.duplicate([40.0, 40.0] ++ List.duplicate(4.0, 8), 6) |> List.flatten()
    assert Enum.sum(trace) / length(trace) < 16.0
    states = simulate(trace)
    assert Enum.all?(states, &(&1.effective_concurrent_agents == 16))
    assert Enum.all?(states, &is_nil(&1.load_envelope_state.last_decrease_ms))
  end

  test "sustained overload halves capacity from the third sample with cooldown" do
    states = simulate(List.duplicate(40.0, 7), 30_000)
    assert Enum.map(states, & &1.effective_concurrent_agents) == [16, 16, 8, 8, 4, 4, 2]
    assert List.last(states).load_envelope_state.last_decrease_ms == 210_000
  end

  test "unavailable and at-target samples break the overload streak" do
    states = simulate([40.0, 40.0, :unavailable, 40.0, 40.0, 16.0, 40.0, 40.0])
    assert Enum.all?(states, &(&1.effective_concurrent_agents == 16))
    assert Enum.map(states, & &1.load_envelope_state.overload_samples) == [1, 2, 0, 1, 2, 0, 1, 2]
  end

  test "disabling the target clears the streak and restores the static cap" do
    state = simulate([40.0, 40.0, 40.0]) |> List.last()
    disabled = DispatchPolicy.update_load_envelope(state, 40.0, nil, 16, 240_000, :unavailable, true)
    assert disabled.effective_concurrent_agents == 16
    assert disabled.load_envelope_state.overload_samples == 0
  end

  test "dispatch sample reuse preserves the streak without counting twice" do
    state = %State{max_concurrent_agents: 16, effective_concurrent_agents: 16, poll_interval_ms: 60_000}
    first = dispatch_sample(state, 1, 60_000)
    reused = dispatch_sample(first, 1, 60_001)
    second = dispatch_sample(reused, 2, 120_000)
    third = dispatch_sample(second, 3, 180_000)
    assert first.load_envelope_state.overload_samples == 1
    assert reused.load_envelope_state.overload_samples == 1
    assert second.effective_concurrent_agents == 16
    assert third.effective_concurrent_agents == 8
  end

  defp dispatch_sample(state, sample_id, now_ms) do
    probes = %{
      load: 40.0,
      target: 1.0,
      schedulers: 16,
      cpu_snapshot: :unavailable,
      sampled_at_ms: sample_id * 60_000,
      sample_id: sample_id,
      memory_mb: :unavailable,
      memory_threshold_mb: nil,
      fd_sample: :unavailable,
      runnable: :unavailable,
      run_queue_threshold: nil,
      load_threshold: nil,
      build_status: %{enabled?: false, capacity: 0, active: 0, queued: 0},
      provider_backends: [],
      github_quota: :available
    }

    Dispatcher.maybe_choose_under_load(state, [], fn current, _issues -> current end, now_ms: now_ms, admission_probes_fun: fn -> probes end)
  end

  defp simulate(trace, period_ms \\ 60_000) do
    initial = %State{max_concurrent_agents: 16, effective_concurrent_agents: 16}

    trace
    |> Enum.with_index(1)
    |> Enum.scan(initial, fn {load, index}, state ->
      DispatchPolicy.update_load_envelope(state, load, 1.0, 16, index * period_ms, :unavailable, true)
    end)
  end
end
