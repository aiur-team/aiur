defmodule Aiur.Orchestrator.PressureResumeTest do
  use Aiur.TestSupport
  alias Aiur.{Config, Workflow}
  alias Aiur.Orchestrator.{Dispatcher, EnvelopeResume, EnvelopeStore, Slots, State}

  setup do
    path = Path.join(System.tmp_dir!(), "pressure-resume-#{System.unique_integer([:positive])}.json")
    previous = Application.get_env(:aiur, :envelope_store_path)
    Application.put_env(:aiur, :envelope_store_path, path)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :envelope_store_path, previous), else: Application.delete_env(:aiur, :envelope_store_path)
      File.rm(path)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 16, target_cpu_pressure: 10.0)
    workflow = Workflow.workflow_file_path()
    write_workflow_file_atomic!(workflow, String.replace(File.read!(workflow), "agent:\n", "agent:\n  target_load_average: null\n"))
    :ok = Aiur.WorkflowStore.force_reload()
    {:ok, path: path}
  end

  test "PSI resumes a saved level with load disabled, fresh samples and its recovery band" do
    assert :ok = EnvelopeStore.save(7, System.schedulers_online(), DateTime.add(DateTime.utc_now(), -720))
    initial = %State{max_concurrent_agents: 16, effective_concurrent_agents: 1, load_envelope_state: EnvelopeResume.boot(Config.settings!().agent)}
    assert Slots.max_concurrent_agent_status(initial).resume_level == 7
    first = dispatch(initial, 1, 2.0)
    assert first.effective_concurrent_agents == 1
    assert Slots.max_concurrent_agent_status(first).resume_level == 7
    assert Slots.max_concurrent_agent_status(first).resume_recorded_ago_seconds in 720..730
    reused = dispatch(first, 1, 2.0)
    assert reused.effective_concurrent_agents == 1
    boundary = dispatch(reused, 2, 8.0)
    assert boundary.effective_concurrent_agents == 1
    states = Enum.scan(3..5, boundary, &dispatch(&2, &1, 7.99))
    assert Enum.map(states, & &1.effective_concurrent_agents) == [2, 4, 7]
    assert Slots.max_concurrent_agent_status(List.last(states)).resume_level == nil
  end

  test "PSI persists five fresh occupied samples and lowers the saved level after sustained pressure", %{path: path} do
    initial = %State{max_concurrent_agents: 16, effective_concurrent_agents: 6, running: Map.new(1..6, &{Integer.to_string(&1), %{}})}
    four = Enum.reduce(1..4, initial, &dispatch(&2, &1, 2.0))
    refute File.exists?(path)
    reused = dispatch(four, 4, 2.0)
    assert Map.get(reused.load_envelope_state, :safe_streak) == 4
    five = dispatch(reused, 5, 2.0)
    assert EnvelopeStore.load(21_600, System.schedulers_online()).safe_level == 6
    overloaded = Enum.reduce(6..8, %{five | effective_concurrent_agents: 8}, &dispatch(&2, &1, 11.0))
    assert overloaded.effective_concurrent_agents == 6
    assert EnvelopeStore.load(21_600, System.schedulers_online()).safe_level == 6
    assert overloaded.load_envelope_state.sustained_decrease?
    assert dispatch(overloaded, 9, 8.0).effective_concurrent_agents == 6
    assert dispatch(overloaded, 9, 7.99).effective_concurrent_agents == 7
  end

  test "host pressure trace keeps the envelope near the demonstrated safe level" do
    initial = %State{max_concurrent_agents: 16, effective_concurrent_agents: 4, running: Map.new(1..4, &{Integer.to_string(&1), %{}})}
    warm_samples = for i <- 1..5, do: {i, 20.0, 4}
    warmed = Enum.reduce(warm_samples, initial, fn {i, pressure, occupied}, current -> dispatch(current, i, pressure, occupied: occupied, target: 35.0, threshold: 60.0) end)
    assert warmed.effective_concurrent_agents == 9
    assert warmed.load_envelope_state.safe_level == 4

    trace = Enum.zip(6..17, Enum.zip([78.0, 82.0, 87.0, 78.0, 82.0, 87.0, 20.0, 20.0, 20.0, 20.0, 20.0, 20.0], [9, 9, 8, 9, 8, 8, 4, 4, 4, 4, 4, 4]))
    pressured = Enum.scan(trace, warmed, fn {i, {pressure, occupied}}, current -> dispatch(current, i, pressure, occupied: occupied, target: 35.0, threshold: 60.0) end)

    effective_caps = Enum.map(pressured, & &1.effective_concurrent_agents)
    assert effective_caps == [9, 9, 5, 5, 4, 4, 5, 6, 7, 8, 9, 10]
    assert_in_delta Enum.sum(effective_caps) / length(effective_caps), 81 / 12, 0.01
  end

  defp dispatch(state, id, pressure, options \\ []) do
    now = id * 120_000
    occupied = Keyword.get(options, :occupied)
    state = if is_integer(occupied), do: %{state | running: Map.new(1..occupied, &{Integer.to_string(&1), %{}})}, else: state

    probes = %{
      cpu_pressure: %{avg10: pressure, avg60: pressure},
      pressure_target: Keyword.get(options, :target, 10.0),
      pressure_threshold: Keyword.get(options, :threshold, 20.0),
      load: 99.0,
      target: nil,
      load_threshold: nil,
      schedulers: System.schedulers_online(),
      cpu_snapshot: :unavailable,
      sampled_at_ms: now,
      sample_id: id,
      memory_mb: 8192,
      memory_threshold_mb: 4096,
      fd_sample: :unavailable,
      runnable: :unavailable,
      run_queue_threshold: nil,
      build_status: %{enabled?: false},
      provider_backends: [],
      github_quota: :available
    }

    Dispatcher.maybe_choose_under_load(state, [], fn current, _ -> current end, now_ms: now, admission_probes_fun: fn -> probes end)
  end
end
