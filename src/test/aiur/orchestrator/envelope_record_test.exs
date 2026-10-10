defmodule Aiur.Orchestrator.EnvelopeRecordTest do
  use Aiur.TestSupport
  alias Aiur.Orchestrator.{CapacityBinding, Dispatcher, DispatchPolicy, EnvelopeResume, EnvelopeStore, Slots, State}
  alias Aiur.Workflow

  setup do
    path = Path.join(System.tmp_dir!(), "record-#{System.unique_integer([:positive])}.json")
    previous = Application.get_env(:aiur, :envelope_store_path)
    Application.put_env(:aiur, :envelope_store_path, path)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :envelope_store_path, previous), else: Application.delete_env(:aiur, :envelope_store_path)
      File.rm(path)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 16)
    {:ok, path: path}
  end

  test "five fresh occupied samples persist a demonstrated level; reuse counts once", %{path: path} do
    four = Enum.reduce(1..4, occupied(6), &dispatch(&2, &1, &1 * 120_000))
    refute File.exists?(path)
    reused = dispatch(four, 4, 480_001)
    assert reused.load_envelope_state.safe_streak == 4
    five = dispatch(reused, 5, 600_000)
    assert five.load_envelope_state.safe_level == 6
    assert EnvelopeStore.load(21_600, 64).safe_level == 6
    contents = File.read!(path)
    six = dispatch(five, 6, 720_000)
    assert File.read!(path) == contents
    assert six.load_envelope_state.record_dirty? == false
  end

  test "lower occupancy restarts demonstration but does not lower a record" do
    state = Enum.reduce(1..4, occupied(6), &dispatch(&2, &1, &1 * 120_000))
    dropped = dispatch(%{state | running: occupied(5).running}, 5, 600_000)
    assert dropped.load_envelope_state.safe_streak == 1
    refute Map.has_key?(dropped.load_envelope_state, :safe_level)
    demonstrated = Enum.reduce(6..9, dropped, &dispatch(&2, &1, &1 * 120_000))
    assert demonstrated.load_envelope_state.safe_level == 5
    empty = dispatch(%{demonstrated | running: %{}}, 10, 1_200_000)
    assert empty.load_envelope_state.safe_level == 5
  end

  test "sustained decrease lowers the record and throttled writes retain the latest level", %{path: path} do
    learned = Enum.reduce(1..5, occupied(6), &dispatch(&2, &1, &1 * 1_000))
    old = File.read!(path)
    state = %{learned | effective_concurrent_agents: 8}
    backed_off = Enum.reduce(6..8, state, fn i, s -> DispatchPolicy.update_load_envelope(s, 80.0, 1.0, 64, i * 1_000, :unavailable, true) end)
    assert backed_off.effective_concurrent_agents == 4
    assert backed_off.load_envelope_state.safe_level == 4
    throttled = EnvelopeResume.persist(backed_off, true, 64, 8_000)
    assert File.read!(path) == old
    assert throttled.load_envelope_state.record_dirty? == true
    assert EnvelopeResume.persist(throttled, false, 64, 70_000) == throttled
    saved = EnvelopeResume.persist(throttled, true, 64, 70_000)
    assert saved.load_envelope_state.record_dirty? == false
    assert EnvelopeStore.load(21_600, 64).safe_level == 4
  end

  test "status carries and renders resume age only during the ramp" do
    now = DateTime.utc_now()
    assert :ok = EnvelopeStore.save(7, System.schedulers_online(), DateTime.add(now, -720))
    state = %{occupied(1) | load_envelope_state: EnvelopeResume.boot(Aiur.Config.settings!().agent)}
    capacity = Slots.max_concurrent_agent_status(state)
    assert capacity.resume_level == 7
    assert capacity.resume_recorded_ago_seconds in 720..722
    assert CapacityBinding.short_label(CapacityBinding.binding(capacity)) == "resuming toward 7 (safe level from 12m ago)"
    reached = Slots.max_concurrent_agent_status(%{state | effective_concurrent_agents: 7})
    assert reached.resume_level == nil
    assert reached.resume_recorded_ago_seconds == nil
  end

  test "sustained overload without a demonstrated record never creates a resume seed" do
    state = %State{max_concurrent_agents: 16, effective_concurrent_agents: 8}
    result = Enum.reduce(1..3, state, fn i, s -> DispatchPolicy.update_load_envelope(s, 80.0, 1.0, 64, i * 120_000, :unavailable, true) end)
    assert result.effective_concurrent_agents == 4
    refute Map.has_key?(result.load_envelope_state, :resume_level)
  end

  test "lower occupancy cannot renew the age of a higher safe record", %{path: path} do
    stamp = DateTime.add(DateTime.utc_now(), -20_000)
    assert :ok = EnvelopeStore.save(7, 64, stamp)
    state = %{occupied(1) | load_envelope_state: Map.merge(occupied(1).load_envelope_state, EnvelopeStore.load(21_600, 64))}
    contents = File.read!(path)
    result = Enum.reduce(1..5, state, &dispatch(&2, &1, &1 * 120_000))
    assert result.load_envelope_state.safe_level == 7
    assert result.load_envelope_state.recorded_at == stamp
    assert File.read!(path) == contents
  end

  defp occupied(n) do
    %State{max_concurrent_agents: 16, effective_concurrent_agents: n, poll_interval_ms: 120_000, running: Map.new(1..n, &{Integer.to_string(&1), %{}})}
  end

  defp dispatch(state, id, now) do
    probes = %{
      load: 48.0,
      target: 1.0,
      schedulers: 64,
      cpu_snapshot: :unavailable,
      sampled_at_ms: now,
      sample_id: id,
      memory_mb: :unavailable,
      memory_threshold_mb: nil,
      fd_sample: :unavailable,
      runnable: :unavailable,
      run_queue_threshold: nil,
      load_threshold: nil,
      build_status: %{enabled?: false},
      provider_backends: [],
      github_quota: :available
    }

    Dispatcher.maybe_choose_under_load(state, [], fn current, _issues -> current end, now_ms: now, admission_probes_fun: fn -> probes end)
  end
end
