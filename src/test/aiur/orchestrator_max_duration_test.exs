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

      log =
        capture_log(fn ->
          send(self(), {:duration_overrun_result, Orchestrator.apply_overrun_check_for_test(state, 60)})
        end)

      assert_receive {:duration_overrun_result, next}

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
      assert log =~ "orchestrator.pause"
      assert log =~ "issue_id=#{issue_id}"
      assert log =~ "issue_identifier=#{identifier}"
      assert log =~ "cause=max_agent_duration"
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

    # Regression for #420: the duration cap is the runaway safety net. An
    # AUTOMATED resume (blocker auto-resume) must not hand a fresh budget,
    # or a duration-capped agent that declared a blocker would reset its
    # clock on every blocker push and never be bounded. Only an OPERATOR
    # "check in, keep going" earns a fresh window.
    test "an automated (blocker) resume PRESERVES the cumulative overrun and does NOT reset the clock" do
      issue_id = "issue-auto-resume-overcap"
      identifier = "AUTO-RESUME"
      # Active runtime already 2h over a 60s cap when it was paused.
      old = DateTime.add(DateTime.utc_now(), -7_200, :second)

      entry =
        issue_id
        |> working_entry(identifier, old, self())
        |> Map.merge(%{
          control: %{status: :paused},
          paused_reason: :max_agent_duration,
          paused_at: old
        })

      state = state_with(%{issue_id => entry})

      # operator?: false == the blocker / pending-auto-resume path.
      assert {{:ok, :resumed}, next} =
               Orchestrator.resume_paused_issue_for_test(state, state.running[issue_id], false)

      assert_receive {:resume_agent, request_id} when is_integer(request_id)

      resumed = next.running[issue_id]
      assert get_in(resumed, [:control, :status]) == :working
      # The reason marker is dropped (entry is working again) so the cap can
      # re-stamp it fresh, but the duration baseline is UNCHANGED — the agent
      # resumes already over the cap.
      refute Map.has_key?(resumed, :paused_reason)
      assert resumed.started_at == old

      # Safety net proof: the very next overrun check at the same cap must
      # RE-PAUSE this still-over-budget agent instead of letting it run free.
      rechecked = Orchestrator.apply_overrun_check_for_test(next, 60)
      assert get_in(rechecked.running, [issue_id, :control, :status]) == :paused
      assert rechecked.running[issue_id].paused_reason == :max_agent_duration
    end

    # Counterpart to the automated case: an explicit operator resume IS a
    # deliberate restart, so the duration clock resets to a full window and
    # the next overrun check leaves the agent working.
    test "an operator resume of a duration-capped agent DOES reset the clock to a fresh budget" do
      issue_id = "issue-operator-resume-overcap"
      identifier = "OP-RESUME"
      old = DateTime.add(DateTime.utc_now(), -7_200, :second)

      entry =
        issue_id
        |> working_entry(identifier, old, self())
        |> Map.merge(%{
          control: %{status: :paused},
          paused_reason: :max_agent_duration,
          paused_at: old
        })

      state = state_with(%{issue_id => entry})

      # Default operator?: true == label-flip / chat resume.
      assert {{:ok, :resumed}, next} =
               Orchestrator.resume_paused_issue_for_test(state, state.running[issue_id])

      resumed = next.running[issue_id]
      assert get_in(resumed, [:control, :status]) == :working
      refute Map.has_key?(resumed, :paused_reason)
      assert DateTime.diff(DateTime.utc_now(), resumed.started_at, :second) < 5

      # Fresh budget: the next overrun check at the same cap leaves it working.
      rechecked = Orchestrator.apply_overrun_check_for_test(next, 60)
      assert get_in(rechecked.running, [issue_id, :control, :status]) == :working
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

  # Regression for #420 problem 1: a duration-capped pause asks the worker
  # to park cooperatively. A truly wedged agent (one never-ending codex
  # turn) never reaches a turn boundary, so it keeps streaming and never
  # parks. Such an entry must NOT sit `:paused` forever — the duration cap
  # can never re-fire on a paused entry and no operator resume is coming —
  # so the stall watchdog escalates it to a terminate after the grace
  # window. Without this a real runaway is the very thing that melts the box.
  describe "wedged over-cap agent escalation (the runaway safety net)" do
    # Unlinked worker pid: the escalation path force-terminates the task, so
    # an unlinked spawn lets that kill land without tearing down the test
    # process (mirrors the working-stall-restart tests).
    defp duration_paused_entry(issue_id, identifier, paused_at, last_codex) do
      worker_pid = spawn(fn -> Process.sleep(:infinity) end)

      issue_id
      |> working_entry(identifier, paused_at, worker_pid)
      |> Map.merge(%{
        control: %{status: :paused},
        paused_reason: :max_agent_duration,
        paused_at: paused_at,
        last_codex_timestamp: last_codex
      })
    end

    test "a wedged over-cap agent is force-terminated after the grace window" do
      issue_id = "issue-wedged-overcap"
      identifier = "WEDGED"
      grace_ms = 60_000

      # Paused for the cap 5 minutes ago, but the codex stream kept ticking
      # AFTER the pause (1 minute ago) — the agent never honored the park.
      paused_at = DateTime.add(DateTime.utc_now(), -300, :second)
      last_codex = DateTime.add(DateTime.utc_now(), -60, :second)

      state = state_with(%{issue_id => duration_paused_entry(issue_id, identifier, paused_at, last_codex)})

      next = Orchestrator.apply_stall_check_for_test(state, grace_ms)

      # The wedged runaway is gone — terminated, not skipped indefinitely.
      refute Map.has_key?(next.running, issue_id)
    end

    test "a cooperatively-parked over-cap agent is left alone (not killed)" do
      issue_id = "issue-parked-overcap"
      identifier = "PARKED"
      grace_ms = 60_000

      # Paused for the cap 5 minutes ago and the codex stream stopped AT the
      # pause boundary (no activity after paused_at) — it parked correctly.
      paused_at = DateTime.add(DateTime.utc_now(), -300, :second)
      last_codex = DateTime.add(paused_at, -5, :second)

      state = state_with(%{issue_id => duration_paused_entry(issue_id, identifier, paused_at, last_codex)})

      next = Orchestrator.apply_stall_check_for_test(state, grace_ms)

      # A correctly-parked agent keeps its slot/workpad for the operator or
      # blocker resume — escalation must not throw it away.
      assert Map.has_key?(next.running, issue_id)
      assert get_in(next.running, [issue_id, :control, :status]) == :paused
    end

    test "a still-streaming over-cap agent inside the grace window is spared" do
      issue_id = "issue-grace-overcap"
      identifier = "GRACE"
      grace_ms = 60_000

      # Paused 10s ago, still streaming — but inside the grace window, so the
      # watchdog gives it a chance to reach its turn boundary and park.
      paused_at = DateTime.add(DateTime.utc_now(), -10, :second)
      last_codex = DateTime.add(DateTime.utc_now(), -2, :second)

      state = state_with(%{issue_id => duration_paused_entry(issue_id, identifier, paused_at, last_codex)})

      next = Orchestrator.apply_stall_check_for_test(state, grace_ms)

      assert Map.has_key?(next.running, issue_id)
      assert get_in(next.running, [issue_id, :control, :status]) == :paused
    end

    test "a manual/blocker pause (no duration reason) is never escalated" do
      issue_id = "issue-manual-pause-streaming"
      identifier = "MANUAL"
      grace_ms = 60_000

      paused_at = DateTime.add(DateTime.utc_now(), -300, :second)
      last_codex = DateTime.add(DateTime.utc_now(), -60, :second)

      # Same wedged shape, but a manual/blocker pause (no :max_agent_duration
      # reason). The escalation is a duration-cap-only safety net; an
      # operator/blocker pause is deliberate idleness and must be preserved.
      entry =
        issue_id
        |> working_entry(identifier, paused_at, self())
        |> Map.merge(%{
          control: %{status: :paused},
          paused_at: paused_at,
          last_codex_timestamp: last_codex
        })

      state = state_with(%{issue_id => entry})

      next = Orchestrator.apply_stall_check_for_test(state, grace_ms)

      assert Map.has_key?(next.running, issue_id)
      assert get_in(next.running, [issue_id, :control, :status]) == :paused
    end
  end
end
