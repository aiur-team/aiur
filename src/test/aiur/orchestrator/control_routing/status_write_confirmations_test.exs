Code.require_file("../../../support/control_routing_fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.ControlRouting.StatusWriteConfirmationsTest do
  use Aiur.TestSupport

  import Aiur.TestSupport.ControlRoutingFixture

  alias Aiur.Orchestrator.{Lifecycle, PauseResume, PushRouting, RuntimeWatchdog}

  describe "control-status writes" do
    test "worker completion expires a pending control instead of leaving it applied or pending" do
      issue_id = unique_id("control-completion-race")
      state = base_state(running: %{issue_id => running_entry(issue_id)})

      {{:ok, request_id}, accepted_state} = PauseResume.pause_agent_reply(state, issue_id)
      assert_receive {:pause_agent, ^request_id, _generation}, 1000

      assert {:noreply, completed_state} =
               Orchestrator.handle_info({:worker_control_state, issue_id, :completed, %{}}, accepted_state)

      assert completed_state.running[issue_id].control.status == :completed

      assert %{status: :expired, expiry: %{reason: :worker_unavailable}} =
               completed_state.control_lifecycle.records[request_id]

      refute Map.has_key?(completed_state.control_lifecycle.pending, issue_id)
    end

    test "a matching acknowledgement is rejected when its expected state version is stale" do
      issue_id = unique_id("control-stale-version")
      state = base_state(running: %{issue_id => running_entry(issue_id)})

      {{:ok, request_id}, accepted_state} = PauseResume.pause_agent_reply(state, issue_id)
      assert_receive {:pause_agent, ^request_id, generation}, 1000

      assert {:noreply, changed_state} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :paused, %{kind: :usage_limit_exhausted}},
                 accepted_state
               )

      assert changed_state.running[issue_id].control.version == 1

      assert {:noreply, rejected_state} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :paused,
                  %{
                    request_id: request_id,
                    generation: generation,
                    kind: :operator_pause
                  }},
                 changed_state
               )

      # Rejection changes nothing but the rejected request's own pending
      # pause reason, which must not outlive the request (#2730).
      assert %{reason: :operator_pause} = changed_state.running[issue_id].pending_pause_reason
      refute Map.has_key?(rejected_state.running[issue_id], :pending_pause_reason)
      assert rejected_state.running[issue_id] == Map.delete(changed_state.running[issue_id], :pending_pause_reason)

      assert %{status: :rejected, rejection: %{class: :already_in_state}} =
               rejected_state.control_lifecycle.records[request_id]
    end

    test "a successful resume clears only its own operator pause reason" do
      issue_id = unique_id("control-resume-pause-owner")

      entry =
        running_entry(issue_id,
          control: %{
            status: :paused,
            can_interrupt: true,
            safe_checkpoints: [:notification],
            application_confirmation: :confirmed,
            generation: 101,
            version: 1
          },
          paused_reason: :operator_pause
        )

      state = base_state(running: %{issue_id => entry})
      {{:ok, :resumed}, accepted_state} = PauseResume.resume_paused_issue(state, entry)
      assert_receive {:resume_agent, request_id, 101}, 1000

      assert {:noreply, resumed_state} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :working, %{request_id: request_id, generation: 101}},
                 accepted_state
               )

      refute Map.has_key?(resumed_state.running[issue_id], :paused_reason)
    end

    test "a successful resume preserves an unrelated waiting reason" do
      issue_id = unique_id("control-resume-waiting-owner")

      entry =
        running_entry(issue_id,
          control: %{
            status: :paused,
            can_interrupt: true,
            safe_checkpoints: [:notification],
            application_confirmation: :confirmed,
            generation: 101,
            version: 1
          },
          paused_reason: :dependency_waiting
        )

      state = base_state(running: %{issue_id => entry})
      assert {:reply, {:ok, 45}, accepted_state} = PauseResume.request_control_call(state, issue_id, :resume, 45)
      assert_receive {:resume_agent, 45, 101}, 1000

      assert {:noreply, resumed_state} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :working, %{request_id: 45, generation: 101}},
                 accepted_state
               )

      assert resumed_state.running[issue_id].paused_reason == :dependency_waiting
    end

    test "an applied resume clears every control-owned waiting cause" do
      for pause_reason <- [:agent_pause_request, :ci_wait, :input_required, :label_override] do
        issue_id = unique_id("control-resume-#{pause_reason}")

        entry =
          running_entry(issue_id,
            control: %{
              status: :paused,
              can_interrupt: true,
              safe_checkpoints: [:notification],
              application_confirmation: :confirmed,
              generation: 101,
              version: 1
            },
            paused_reason: pause_reason
          )

        state = base_state(running: %{issue_id => entry})

        assert {:reply, {:ok, request_id}, accepted_state} =
                 PauseResume.request_control_call(state, issue_id, :resume, 50)

        assert_receive {:resume_agent, ^request_id, 101}, 1000

        assert {:noreply, resumed_state} =
                 Orchestrator.handle_info(
                   {:worker_control_state, issue_id, :working, %{request_id: request_id, generation: 101}},
                   accepted_state
                 )

        refute Map.has_key?(resumed_state.running[issue_id], :paused_reason)
      end
    end

    test "label override, duration cap, and agent pause requests wait for worker evidence" do
      issue_id = unique_id("control-pause-sources")
      entry = running_entry(issue_id, started_at: DateTime.add(DateTime.utc_now(), -120, :second))
      state = base_state(running: %{issue_id => entry})
      paused_issue = %{entry.issue | paused: true}

      label_pending_state = PauseResume.pause_issue_for_label_override(state, paused_issue)
      assert_receive {:pause_agent, label_request_id, 101}, 1000
      assert label_pending_state.running[issue_id].control.status == :working

      assert label_pending_state.running[issue_id].pending_pause_reason == %{
               request_id: label_request_id,
               reason: :label_override
             }

      duration_pending_state =
        RuntimeWatchdog.maybe_pause_overrunning_entry(
          state,
          issue_id,
          entry,
          DateTime.utc_now(),
          60
        )

      assert_receive {:pause_agent, duration_request_id, 101}, 1000
      assert duration_pending_state.running[issue_id].control.status == :working

      assert duration_pending_state.running[issue_id].pending_pause_reason == %{
               request_id: duration_request_id,
               reason: :max_agent_duration
             }

      agent_pending_state = PushRouting.maybe_pause_on_request(state, issue_id)
      assert_receive {:pause_agent, agent_request_id, 101}, 1000
      assert agent_pending_state.running[issue_id].control.status == :working

      assert agent_pending_state.running[issue_id].pending_pause_reason == %{
               request_id: agent_request_id,
               reason: :agent_pause_request
             }
    end

    test "worker pause confirmation preserves capabilities and freezes the runtime clock" do
      issue_id = unique_id("control-pause")
      started_at = DateTime.add(DateTime.utc_now(), -30, :second)

      entry =
        running_entry(issue_id,
          started_at: started_at,
          control: %{
            status: :working,
            can_interrupt: true,
            safe_checkpoints: [:notification]
          }
        )

      state = base_state(running: %{issue_id => entry})

      assert {:noreply, next} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :paused, %{kind: :usage_limit_exhausted}},
                 state
               )

      paused = Map.fetch!(next.running, issue_id)

      assert paused.control == %{
               status: :paused,
               can_interrupt: true,
               safe_checkpoints: [:notification]
             }

      assert paused.paused_reason == :usage_limit_exhausted
      assert %DateTime{} = paused.paused_at
      assert paused.started_at == started_at
    end

    test "duplicate transition and unknown worker confirmation are exact no-ops" do
      issue_id = unique_id("control-idempotent")
      paused_at = DateTime.add(DateTime.utc_now(), -10, :second)

      entry =
        running_entry(issue_id,
          control: %{status: :paused, can_interrupt: true},
          paused_at: paused_at,
          paused_reason: :operator_pause
        )

      state = base_state(running: %{issue_id => entry})

      assert state ==
               Orchestrator.transition_control_status(
                 state,
                 entry,
                 :paused,
                 "duplicate.confirmation"
               )

      assert {:noreply, ^state} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :paused, %{kind: :usage_limit_exhausted}},
                 state
               )

      assert {:noreply, ^state} =
               Orchestrator.handle_info(
                 {:worker_control_state, "missing-#{issue_id}", :paused, %{kind: :usage_limit_exhausted}},
                 state
               )

      assert state.running[issue_id].paused_at == paused_at
    end

    test "working confirmation thaws the pause clock and preserves unrelated entry data" do
      issue_id = unique_id("control-working")
      started_at = DateTime.add(DateTime.utc_now(), -60, :second)
      paused_at = DateTime.add(DateTime.utc_now(), -5, :second)

      entry =
        running_entry(issue_id,
          control: %{status: :paused, can_interrupt: true},
          started_at: started_at,
          paused_at: paused_at,
          routing_marker: :preserved
        )

      state = base_state(running: %{issue_id => entry})
      before_resume = DateTime.utc_now()

      assert {:noreply, next} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :working},
                 state
               )

      after_resume = DateTime.utc_now()
      working = Map.fetch!(next.running, issue_id)
      shift_seconds = DateTime.diff(working.started_at, started_at, :second)
      earliest_shift = DateTime.diff(before_resume, paused_at, :second)
      latest_shift = DateTime.diff(after_resume, paused_at, :second)

      assert working.control.status == :working
      assert working.control.can_interrupt
      assert working.routing_marker == :preserved
      assert is_nil(working.paused_at)
      assert shift_seconds in earliest_shift..latest_shift
    end

    test "the first resumed agent wakes a widened idle poll deadline" do
      issue_id = unique_id("control-working-wake")

      entry =
        running_entry(issue_id,
          control: %{status: :paused, can_interrupt: true},
          paused_at: DateTime.utc_now()
        )

      state = base_state(running: %{issue_id => entry}) |> Lifecycle.schedule_tick(60_000)

      assert {:noreply, next} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :working},
                 state
               )

      assert next.next_poll_due_at_ms <= System.monotonic_time(:millisecond)
      assert_receive {:tick, _token}, 1000
    end

    test "a legacy resume also wakes a widened idle poll deadline" do
      issue_id = unique_id("legacy-control-working-wake")

      entry =
        running_entry(issue_id,
          control: %{status: :paused, can_interrupt: true},
          paused_at: DateTime.utc_now()
        )

      state = base_state(running: %{issue_id => entry}) |> Lifecycle.schedule_tick(60_000)

      assert {{:ok, :resumed}, next} = PauseResume.resume_issue(state, issue_id)
      assert next.next_poll_due_at_ms <= System.monotonic_time(:millisecond)
      assert_receive {:resume_agent, _request_id}, 1000
      assert_receive {:tick, _token}, 1000
    end
  end
end
