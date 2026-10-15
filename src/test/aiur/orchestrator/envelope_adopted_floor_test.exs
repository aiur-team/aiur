defmodule Aiur.Orchestrator.EnvelopeAdoptedFloorTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.{DispatchPolicy, State}

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), max_concurrent_agents: 16)
    :ok
  end

  test "first sample restores occupied capacity above a lower persisted hint" do
    state = boot(6, 4)
    restored = sample(state, 48.0, 1)
    assert restored.effective_concurrent_agents == 6
    assert restored.load_envelope_state.bootstrap_complete?
    assert restored.load_envelope_state.resume_level == 4
  end

  # Future regression guard: restoring existing workers must preserve #3768 cold admission.
  test "an empty fleet retains cold bootstrap and persisted fast ramp" do
    state = boot(0, 4)
    frozen = sample(state, :unavailable, 1)
    assert frozen.effective_concurrent_agents == 1
    refute frozen.load_envelope_state.bootstrap_complete?
    seeded = sample(frozen, 48.0, 2)
    assert seeded.effective_concurrent_agents == 1
    assert sample(seeded, 48.0, 3).effective_concurrent_agents == 2
  end

  test "occupied bootstrap keeps the higher valid hint and respects the configured ceiling" do
    restored = sample(boot(3, 7), 48.0, 1)
    assert restored.effective_concurrent_agents == 7
    capped = sample(%{boot(6, 9) | session_max_concurrent_agents: 5}, 48.0, 1)
    assert capped.effective_concurrent_agents == 5
  end

  test "unavailable load restores existing capacity without turning the floor into a permanent minimum" do
    restored = sample(boot(6, 4), :unavailable, 1)
    assert restored.effective_concurrent_agents == 6
    backed_off = Enum.reduce(2..4, restored, fn i, state -> sample(state, 80.0, i) end)
    assert backed_off.effective_concurrent_agents == 3
  end

  defp boot(occupied, resume) do
    running = Map.new(List.duplicate(nil, occupied) |> Enum.with_index(), fn {_, i} -> {Integer.to_string(i), %{control: %{status: :working}}} end)
    state = %State{max_concurrent_agents: 16, effective_concurrent_agents: 1, running: running}
    put_in(state.load_envelope_state[:resume_level], resume)
  end

  defp sample(state, load, i), do: DispatchPolicy.update_load_envelope(state, load, 1.0, 64, i * 120_000, :unavailable, true)
end
