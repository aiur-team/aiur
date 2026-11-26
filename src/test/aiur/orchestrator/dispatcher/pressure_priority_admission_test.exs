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
    assert held.effective_concurrent_agents == 5
    assert held.priority_dispatch_reservations == %{}
    assert_received {:candidate, "urgent", slots, :dispatch, _dispatched}
    assert slots > 0
    refute_received {:candidate, "routine", _, _, _}
  end

  test "a running P1 is skipped so a waiting P1 can use the pressure bypass" do
    running_p1 = %{issue("urgent-running") | priority: 1}
    waiting_p1 = %{issue("urgent-waiting") | priority: 1}
    running = running_agents(6) |> Map.put(running_p1.id, Map.put(running_entry(running_p1.id), :issue, running_p1))

    state = %{state(7) | running: running}

    choose = fn selected_state, [selected] ->
      assert selected.id == waiting_p1.id
      Process.put({Aiur.Handoff, :dispatch_hold}, true)

      try do
        dispatched =
          Dispatcher.maybe_choose(selected_state, [selected],
            issue_fetcher: fn [_id] -> {:ok, [waiting_p1]} end,
            blocked_by_hydrator: fn issue -> {:ok, issue} end
          )

        send(self(), {:selected, selected.id, selected_state.priority_dispatch_reservations[selected.id], dispatched})
        dispatched
      after
        Process.delete({Aiur.Handoff, :dispatch_hold})
      end
    end

    result =
      Dispatcher.maybe_choose_under_load(state, [running_p1, waiting_p1], choose,
        admission_probes_fun: fn -> probes() end,
        now_ms: 1_001
      )

    assert_received {:selected, "urgent-waiting", 9, _dispatched}
    assert result.priority_dispatch_reservations == %{}
  end

  test "a skipped chooser does not leave a priority reservation" do
    p1 = %{issue("urgent-skipped") | priority: 1}

    result =
      Dispatcher.maybe_choose_under_load(state(7), [p1], fn chosen_state, [_selected] -> chosen_state end,
        admission_probes_fun: fn -> probes() end,
        now_ms: 1_001
      )

    assert result.priority_dispatch_reservations == %{}
    refute Enum.any?(result.tracker_tasks, fn {_ref, job} -> job.key == {:dispatch, p1.id} end)
  end

  test "repeated P1 bypasses stay tied to the envelope and cannot leak slots to P3" do
    first = %{issue("urgent-first") | priority: 1}
    second = %{issue("urgent-second") | priority: 1}
    p3 = %{issue("routine") | priority: 3}

    record_reservation = fn selected_state, [candidate] ->
      send(self(), {:reservation, candidate.id, selected_state.priority_dispatch_reservations[candidate.id]})
      selected_state
    end

    first_poll =
      Dispatcher.maybe_choose_under_load(state(7), [first], record_reservation,
        admission_probes_fun: fn -> probes() end,
        now_ms: 1_001
      )

    assert first_poll.effective_concurrent_agents == 5
    assert_received {:reservation, "urgent-first", first_limit}
    assert first_limit <= first_poll.effective_concurrent_agents + 4

    second_poll =
      Dispatcher.maybe_choose_under_load(%{first_poll | running: running_agents(8), priority_dispatch_reservations: %{}}, [second], record_reservation,
        admission_probes_fun: fn -> probes(%{sample_id: :second_sample, sampled_at_ms: 2_000}) end,
        now_ms: 2_001
      )

    assert_received {:reservation, "urgent-second", second_limit}
    assert second_limit <= second_poll.effective_concurrent_agents + 4
    assert second_poll.effective_concurrent_agents < 12

    no_p3 = fn selected_state, [routine] ->
      assert {:skip, :fleet_capacity} = DispatchPolicy.dispatch_decision(routine, selected_state)
      selected_state
    end

    after_pressure_clears =
      Dispatcher.maybe_choose_under_load(%{second_poll | running: running_agents(9)}, [p3], no_p3,
        admission_probes_fun: fn -> probes(%{cpu_pressure: %{avg60: 50.0}, sample_id: :third_sample, sampled_at_ms: 3_000}) end,
        now_ms: 3_001
      )

    refute Map.has_key?(after_pressure_clears.priority_dispatch_reservations, p3.id)
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
