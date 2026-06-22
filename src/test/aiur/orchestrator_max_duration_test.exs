defmodule Aiur.OrchestratorMaxDurationTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator

  # A live process that swallows whatever control messages the
  # orchestrator sends it, so `send_pause_control_message` /
  # `send_resume_control_message` resolve to `{:ok, _}` instead of
  # `{:error, :agent_finished}`.
  defp fake_agent_loop do
    receive do
      _ -> fake_agent_loop()
    end
  end

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

      state = state_with(%{issue_id => working_entry(issue_id, identifier, old, nil)})

      next = Orchestrator.apply_overrun_check_for_test(state, 60)

      # Entry survives — pausing keeps the agent in the list, not killed.
      assert Map.has_key?(next.running, issue_id)
      refute Map.has_key?(next.retry_attempts, issue_id)

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
    setup do
      pid = spawn_link(fn -> fake_agent_loop() end)
      %{pid: pid}
    end

    test "flips back to :working, clears the reason, and hands a fresh budget", %{pid: pid} do
      issue_id = "issue-dur-resume"
      identifier = "DUR-RESUME"
      old = DateTime.add(DateTime.utc_now(), -7_200, :second)

      entry =
        issue_id
        |> working_entry(identifier, old, pid)
        |> Map.merge(%{
          control: %{status: :paused},
          paused_reason: :max_agent_duration,
          paused_at: old
        })

      state = state_with(%{issue_id => entry})

      assert {{:ok, :resumed}, next} =
               Orchestrator.resume_paused_issue_for_test(state, state.running[issue_id])

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

    test "a manual pause (no duration reason) keeps its accrued runtime on resume", %{pid: pid} do
      issue_id = "issue-manual-resume"
      identifier = "MAN-RESUME"
      started = DateTime.add(DateTime.utc_now(), -300, :second)
      paused_at = DateTime.add(DateTime.utc_now(), -100, :second)

      entry =
        issue_id
        |> working_entry(identifier, started, pid)
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
  end
end
