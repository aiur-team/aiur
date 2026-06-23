defmodule Aiur.OrchestratorMaxDurationTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator

  defp working_entry(issue_id, identifier, started_at, pid) do
    %{
      pid: pid,
      ref: nil,
      identifier: identifier,
      issue: %Issue{id: issue_id, state: "in-progress", identifier: identifier},
      started_at: started_at,
      control: %{status: :working}
    }
  end

  defp state_with(running) do
    %Orchestrator.State{
      running: running,
      claimed: MapSet.new(Map.keys(running)),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{},
      max_concurrent_agents: 6
    }
  end

  describe "overrunning_entry?/3 (max_agent_duration cap)" do
    test "fires only for actively-running agents past the cap" do
      now = DateTime.utc_now()
      old = DateTime.add(now, -120, :second)
      recent = DateTime.add(now, -10, :second)

      # active agent running 120s against a 60s cap -> overrunning
      assert Orchestrator.overrunning_entry?(%{started_at: old}, now, 60)

      # active agent only 10s in -> keep
      refute Orchestrator.overrunning_entry?(%{started_at: recent}, now, 60)

      # paused agents are intentionally idle -> never re-flagged, even
      # when their start is old (running_seconds is frozen on pause).
      refute Orchestrator.overrunning_entry?(
               %{started_at: old, control: %{status: :paused}},
               now,
               60
             )

      # deactivated agents have no live task to act on -> excluded
      refute Orchestrator.overrunning_entry?(
               %{started_at: old, control: %{status: :deactivated}},
               now,
               60
             )

      # missing started_at -> running_seconds 0 -> not overrunning
      refute Orchestrator.overrunning_entry?(%{}, now, 60)
    end
  end

  describe "max_agent_duration pauses (does not kill) the agent" do
    test "an overrunning working entry transitions to :paused with the duration reason" do
      issue_id = "issue-dur-pause"
      identifier = "DUR-1"
      old = DateTime.add(DateTime.utc_now(), -3_600, :second)

      # pid: self() so the cooperative {:pause_agent} control message is
      # actually delivered (and assertable) rather than silently dropped
      # as {:error, :agent_finished}.
      state = state_with(%{issue_id => working_entry(issue_id, identifier, old, self())})

      # Seed an unrelated retry so "no retry scheduled" is a real assertion
      # against a non-empty map, not a vacuous pass on the empty default.
      state = %{state | retry_attempts: %{"other-issue" => %{identifier: "X", error: "stalled"}}}

      next = Orchestrator.apply_overrun_check_for_test(state, 60)

      # The worker is told to park cooperatively — this is the load-bearing
      # behavior that replaced the old terminate+retry kill.
      assert_receive {:pause_agent, request_id} when is_integer(request_id)

      # Entry survives — pausing keeps the agent in the list, not killed —
      # and no retry is scheduled for it (the kill path is gone).
      assert Map.has_key?(next.running, issue_id)
      assert next.retry_attempts == state.retry_attempts

      entry = next.running[issue_id]
      assert get_in(entry, [:control, :status]) == :paused
      assert entry.paused_reason == :max_agent_duration

      # paused_at is stamped so the runtime clock freezes while paused.
      assert %DateTime{} = entry.paused_at
    end

    test "an entry still under the cap is left untouched" do
      issue_id = "issue-dur-under"
      identifier = "DUR-2"
      recent = DateTime.add(DateTime.utc_now(), -10, :second)

      state = state_with(%{issue_id => working_entry(issue_id, identifier, recent, nil)})

      next = Orchestrator.apply_overrun_check_for_test(state, 60)

      assert get_in(next.running, [issue_id, :control, :status]) == :working
      refute Map.has_key?(next.running[issue_id], :paused_reason)
    end

    test "a duration-paused agent reserves its slot like a manual pause" do
      issue_id = "issue-dur-slot"
      identifier = "DUR-3"
      old = DateTime.add(DateTime.utc_now(), -3_600, :second)

      state = state_with(%{issue_id => working_entry(issue_id, identifier, old, nil)})
      paused = Orchestrator.apply_overrun_check_for_test(state, 60)

      status = Orchestrator.slot_status_for_test(paused)
      assert status.active == 0
      assert status.paused == 1
    end
  end

  describe "resuming a duration-paused agent" do
    test "flips back to :working, clears the reason, and hands a fresh budget" do
      issue_id = "issue-dur-resume"
      identifier = "DUR-RESUME"
      old = DateTime.add(DateTime.utc_now(), -7_200, :second)

      # pid: self() so we can assert the worker is told to resume.
      entry =
        issue_id
        |> working_entry(identifier, old, self())
        |> Map.merge(%{
          control: %{status: :paused},
          paused_reason: :max_agent_duration,
          paused_at: old
        })

      state = state_with(%{issue_id => entry})

      assert {{:ok, :resumed}, next} =
               Orchestrator.resume_paused_issue_for_test(state, state.running[issue_id])

      assert_receive {:resume_agent, request_id} when is_integer(request_id)

      resumed = next.running[issue_id]
      assert get_in(resumed, [:control, :status]) == :working
      refute Map.has_key?(resumed, :paused_reason)

      # started_at was reset to ~now, so the agent gets a full fresh
      # duration window instead of resuming already over the cap.
      assert DateTime.diff(DateTime.utc_now(), resumed.started_at, :second) < 5

      # The very next overrun check at the same cap must NOT re-pause it.
      rechecked = Orchestrator.apply_overrun_check_for_test(next, 60)
      assert get_in(rechecked.running, [issue_id, :control, :status]) == :working
    end

    test "a manual pause (no duration reason) keeps its accrued runtime on resume" do
      issue_id = "issue-manual-resume"
      identifier = "MAN-RESUME"
      started = DateTime.add(DateTime.utc_now(), -300, :second)
      paused_at = DateTime.add(DateTime.utc_now(), -100, :second)

      entry =
        issue_id
        |> working_entry(identifier, started, self())
        |> Map.merge(%{control: %{status: :paused}, paused_at: paused_at})

      state = state_with(%{issue_id => entry})

      assert {{:ok, :resumed}, next} =
               Orchestrator.resume_paused_issue_for_test(state, state.running[issue_id])

      resumed = next.running[issue_id]
      assert get_in(resumed, [:control, :status]) == :working
      refute Map.has_key?(resumed, :paused_reason)

      # Manual resume only shifts started_at forward by the paused
      # interval (~100s); it is NOT reset to now, so the accrued ~200s of
      # active runtime is preserved.
      assert DateTime.diff(DateTime.utc_now(), resumed.started_at, :second) > 150
    end

    test "resume is refused at the concurrency cap and leaves the duration pause intact" do
      paused_id = "issue-dur-capped"
      active_id = "issue-active-holder"
      old = DateTime.add(DateTime.utc_now(), -7_200, :second)

      paused_entry =
        paused_id
        |> working_entry("DUR-CAPPED", old, self())
        |> Map.merge(%{
          control: %{status: :paused},
          paused_reason: :max_agent_duration,
          paused_at: old
        })

      # A single active agent already occupies the only slot.
      active_entry = working_entry(active_id, "ACTIVE-1", DateTime.utc_now(), self())

      state = %{
        state_with(%{paused_id => paused_entry, active_id => active_entry})
        | max_concurrent_agents: 1
      }

      assert {{:error, :max_concurrent_agents_reached}, next} =
               Orchestrator.resume_paused_issue_for_test(state, state.running[paused_id])

      # The refused resume must not wake the worker, clear the reason, or
      # reset the duration clock — the agent stays duration-paused.
      refute_received {:resume_agent, _request_id}
      paused = next.running[paused_id]
      assert get_in(paused, [:control, :status]) == :paused
      assert paused.paused_reason == :max_agent_duration
      assert paused.started_at == old
    end
  end
end
