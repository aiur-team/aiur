defmodule Aiur.Orchestrator.EnvelopeResumeTest do
  use Aiur.TestSupport
  alias Aiur.Orchestrator.{DispatchPolicy, State}
  alias Aiur.Workflow

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 16)
    :ok
  end

  test "resume preserves bootstrap and frozen samples then reaches seven" do
    initial = initial(7)
    frozen = Enum.reduce(1..8, initial, fn i, state -> sample(state, :unavailable, i) end)
    assert frozen.effective_concurrent_agents == 1
    assert frozen.load_envelope_state.bootstrap_complete? == false
    states = Enum.scan(1..5, frozen, fn i, state -> sample(state, 48.0, i) end)
    assert [1 | Enum.map(states, & &1.effective_concurrent_agents)] == [1, 1, 2, 4, 7, 8]
    held = sample(initial, 80.0, 1) |> sample(80.0, 2)
    assert held.effective_concurrent_agents == 1
  end

  test "lagged agent load with two-sample spikes preserves backoff rate after both ramps recover" do
    baseline = simulate(nil)
    resumed = simulate(7)
    baseline_recovered = Enum.find_index(baseline, &(&1 >= 7))
    resumed_recovered = Enum.find_index(resumed, &(&1 >= 7))
    assert resumed_recovered <= 6
    assert resumed_recovered < baseline_recovered
    # Operator decision: compare the same recovered occupancy and lag history.
    steady_baseline = simulate(nil, 7)
    steady_resumed = simulate(7, 7)
    assert halvings(steady_resumed) <= halvings(steady_baseline)

    IO.inspect(
      %{
        startup_main: halvings(baseline),
        startup_resume: halvings(resumed),
        steady_main: halvings(steady_baseline),
        steady_resume: halvings(steady_resumed),
        main_recovery_sample: baseline_recovered,
        resume_recovery_sample: resumed_recovered
      },
      label: "envelope simulation"
    )
  end

  test "cap raise retains the higher record and fast probing stops at half target" do
    state = %{initial(20) | effective_concurrent_agents: 16, session_max_concurrent_agents: 24}
    states = Enum.scan(1..3, state, fn i, current -> sample(current, 48.0, i) end)
    assert Enum.map(states, & &1.effective_concurrent_agents) == [19, 20, 21]
    assert sample(List.last(states), 25.0, 4).effective_concurrent_agents == 24
    assert sample(List.last(states), 32.0, 4).effective_concurrent_agents == 22
    assert DispatchPolicy.update_load_envelope(state, 0.0, nil, 64, 1, :unavailable, true).effective_concurrent_agents == 24
  end

  defp initial(resume) do
    state = %State{max_concurrent_agents: 16, effective_concurrent_agents: 1}
    put_in(state.load_envelope_state[:resume_level], resume)
  end

  defp simulate(resume, effective \\ 1) do
    state = %{initial(resume) | effective_concurrent_agents: effective}
    state = put_in(state.load_envelope_state[:bootstrap_complete?], effective > 1)

    {_, values} =
      Enum.reduce(1..120, {state, [effective, effective]}, fn i, {state, history} ->
        lagged = Enum.at(history, -2)
        spike = if rem(i, 10) in [8, 9], do: 16.0, else: 0.0
        next = if is_nil(resume), do: baseline_sample(state, lagged * 8.0 + spike, i), else: sample(state, lagged * 8.0 + spike, i)
        {next, history ++ [next.effective_concurrent_agents]}
      end)

    values
  end

  defp baseline_sample(state, load, i) do
    overload = Aiur.Orchestrator.SustainedLoad.count(load, 1.0, 64, state.load_envelope_state)

    options = %{
      target: 1.0,
      schedulers: 64,
      static_limit: 16,
      ramp_step: 1,
      cooldown_ms: 60_000,
      now_ms: i * 120_000,
      cpu_headroom: :unavailable,
      queued_work?: true,
      used_slots: state.effective_concurrent_agents,
      bootstrap_complete?: state.effective_concurrent_agents > 1 or i > 1,
      overload_samples: overload
    }

    {effective, decreased_at} = DispatchPolicy.load_envelope(state.effective_concurrent_agents, state.load_envelope_state.last_decrease_ms, load, options)
    %{state | effective_concurrent_agents: effective, load_envelope_state: %{last_decrease_ms: decreased_at, overload_samples: overload}}
  end

  defp halvings(values), do: values |> Enum.chunk_every(2, 1, :discard) |> Enum.count(fn [a, b] -> b < a end)
  defp sample(state, load, i), do: DispatchPolicy.update_load_envelope(state, load, 1.0, 64, i * 120_000, :unavailable, true)
end
