defmodule Aiur.Orchestrator.Dispatcher.PressurePriorityAdmissionTest do
  use Aiur.DispatcherTestSupport

  alias Aiur.Orchestrator.PressureAdmission

  defp probes(overrides \\ %{}) do
    Map.merge(
      %{
        cpu_pressure: %{avg60: 80.0},
        pressure_threshold: 60.0,
        pressure_target: 30.0,
        cpu_snapshot: :unavailable,
        memory_mb: :unavailable,
        memory_threshold_mb: nil,
        fd_sample: :unavailable,
        runnable: :unavailable,
        run_queue_threshold: nil,
        schedulers: 16,
        load: 100.9,
        load_threshold: 1.5,
        target: nil,
        provider_backends: [],
        github_quota: :available,
        sampled_at_ms: 1_000,
        sample_id: :same_sample
      },
      overrides
    )
  end

  defp running_agents(count) do
    Map.new(1..count, fn index ->
      id = "active-#{index}"
      {id, running_entry(id)}
    end)
  end

  defp state(occupied, effective \\ 5, maximum \\ 12) do
    %State{
      max_concurrent_agents: maximum,
      effective_concurrent_agents: effective,
      running: running_agents(occupied),
      load_envelope_state: %{
        sample_id: :same_sample,
        sampled_at_ms: 1_000,
        cpu_snapshot: nil,
        last_decrease_ms: nil,
        bootstrap_complete?: true
      }
    }
  end

  test "an incident-shaped CPU hold gives one slot to P1 and leaves P3 held" do
    p1 = %{issue("urgent") | priority: 1}
    p3 = %{issue("routine") | priority: 3}

    choose = fn selected_state, selected ->
      [urgent] = selected
      availability = Slots.available_slots(selected_state)
      decision = DispatchPolicy.dispatch_decision(urgent, selected_state)

      # Exercise Dispatcher.maybe_choose with the real candidate policy. Hold
      # the final worker launch so the test cannot start an agent process.
      Process.put({Aiur.Handoff, :dispatch_hold}, true)

      try do
        dispatched =
          Dispatcher.maybe_choose(selected_state, [urgent],
            issue_fetcher: fn [_id] -> {:ok, [urgent]} end,
            blocked_by_hydrator: fn issue -> {:ok, issue} end
          )

        send(self(), {:candidate, urgent.id, availability, decision, dispatched})
        dispatched
      after
        Process.delete({Aiur.Handoff, :dispatch_hold})
      end
    end

    held =
      Dispatcher.maybe_choose_under_load(state(7), [p1, p3], choose,
        admission_probes_fun: fn -> probes() end,
        now_ms: 1_001
      )

    assert held.capacity_hold.signal == :cpu_pressure
    assert_received {:candidate, "urgent", slots, :dispatch, _dispatched}
    assert slots > 0
    refute_received {:candidate, "routine", _, _, _}
  end

  test "a P1 stays held above the PSI hard ceiling" do
    p1 = %{issue("urgent") | priority: 1}
    choose = fn state, _selected -> flunk("unexpected bypass at hard load ceiling: #{inspect(state)}") end

    _held =
      Dispatcher.maybe_choose_under_load(state(7), [p1], choose,
        admission_probes_fun: fn -> probes(%{cpu_pressure: %{avg60: 90.1}}) end,
        now_ms: 1_001
      )
  end

  test "the bypass cannot exceed four slots above the effective envelope or the static maximum" do
    p1 = %{issue("urgent") | priority: 1}
    choose = fn state, _selected -> flunk("unexpected bypass above bounded capacity: #{inspect(state)}") end

    _held =
      Dispatcher.maybe_choose_under_load(state(9), [p1], choose,
        admission_probes_fun: fn -> probes() end,
        now_ms: 1_001
      )

    _at_static_max =
      Dispatcher.maybe_choose_under_load(state(12, 10, 12), [p1], choose,
        admission_probes_fun: fn -> probes() end,
        now_ms: 1_001
      )

    assert PressureAdmission.priority_bypass_allowed?(%{cpu_pressure: %{avg60: 90.1}, load: 100.9, load_threshold: 1.5, schedulers: 16}) ==
             false
  end
end
