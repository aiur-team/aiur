defmodule Aiur.OrchestratorControlRoutingTest do
  use Aiur.TestSupport

  alias Aiur.{AgentPubSub, Issue, TrackerIdentity}
  alias Aiur.Orchestrator.{ControlLifecycle, Lifecycle, PauseResume, PushRouting, RuntimeWatchdog, State}

  describe "control-status writes" do
    test "accepted pause stays working until matching worker evidence applies it" do
      issue_id = unique_id("control-correlated-pause")
      entry = running_entry(issue_id)
      state = base_state(running: %{issue_id => entry})

      {{:ok, request_id}, accepted_state} = PauseResume.pause_agent_reply(state, issue_id)

      assert accepted_state.running[issue_id].control.status == :working
      assert accepted_state.control_lifecycle.pending[issue_id] == request_id
      assert %{request_id: ^request_id, status: :accepted} = accepted_state.control_lifecycle.records[request_id]
      assert_receive {:pause_agent, ^request_id, generation}

      assert {:noreply, ^accepted_state} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :paused,
                  %{
                    request_id: request_id,
                    generation: generation + 1,
                    kind: :operator_pause
                  }},
                 accepted_state
               )

      replacement_state = put_in(accepted_state.running[issue_id].control.generation, generation + 1)

      assert {:noreply, stale_generation_state} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :paused,
                  %{
                    request_id: request_id,
                    generation: generation,
                    kind: :operator_pause
                  }},
                 replacement_state
               )

      assert stale_generation_state.running[issue_id] == replacement_state.running[issue_id]

      assert %{status: :rejected, rejection: %{class: :stale_generation}} =
               stale_generation_state.control_lifecycle.records[request_id]

      assert {:noreply, applied_state} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :paused,
                  %{
                    request_id: request_id,
                    generation: generation,
                    kind: :operator_pause
                  }},
                 accepted_state
               )

      assert applied_state.running[issue_id].control.status == :paused
      assert applied_state.running[issue_id].paused_reason == :operator_pause
      assert applied_state.control_lifecycle.records[request_id].status == :applied
      refute Map.has_key?(applied_state.control_lifecycle.pending, issue_id)
    end

    test "an OpenAI-compat backend pause is requested, confirmed, and observed to take effect" do
      issue_id = unique_id("control-openai-compat-pause")

      # Control map exactly as `Dispatcher.default_running_control/2` builds it
      # for an OpenAI-compat backend (deepseek/kimi/openrouter) since #1966:
      # the worker echoes the orchestrator's `request_id`/`generation` at its
      # pause checkpoint, so it declares correlated application confirmation.
      entry =
        running_entry(issue_id,
          control: %{
            status: :working,
            can_interrupt: false,
            safe_checkpoints: [:notification, :tool_result],
            application_confirmation: :confirmed,
            generation: 101,
            version: 0
          }
        )

      state = base_state(running: %{issue_id => entry})

      # The pause is admitted and routed to the worker — not rejected as
      # `:unsupported` by the control preflight.
      assert {:reply, {:ok, request_id}, accepted_state} =
               PauseResume.request_control_call(state, issue_id, :pause, 55)

      assert_receive {:pause_agent, ^request_id, 101}
      assert accepted_state.running[issue_id].control.status == :working

      # The worker confirms with the correlated evidence it echoes from the
      # pause control message; the orchestrator applies it.
      assert {:noreply, applied_state} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :paused, %{reason: :operator_pause, request_id: request_id, generation: 101}},
                 accepted_state
               )

      assert applied_state.running[issue_id].control.status == :paused
      assert applied_state.running[issue_id].paused_reason == :operator_pause
      assert applied_state.control_lifecycle.records[request_id].status == :applied
      refute Map.has_key?(applied_state.control_lifecycle.pending, issue_id)
    end

    test "a supplied control request ID retries the original intent without routing twice" do
      issue_id = unique_id("control-idempotent-request")
      state = base_state(running: %{issue_id => running_entry(issue_id)})

      assert {:reply, {:ok, 42}, accepted_state} =
               PauseResume.request_control_call(state, issue_id, :pause, 42)

      assert_receive {:pause_agent, 42, 101}

      assert {:reply, {:ok, 42}, ^accepted_state} =
               PauseResume.request_control_call(accepted_state, issue_id, :pause, 42)

      refute_receive {:pause_agent, 42, _generation}

      assert [%{request_id: 42, status: :accepted}] =
               ControlLifecycle.history(accepted_state.control_lifecycle, issue_id)
    end

    test "resume supersedes a pending pause and the stale pause cannot apply later" do
      issue_id = unique_id("control-resume-pending-pause")
      entry = running_entry(issue_id)
      state = base_state(running: %{issue_id => entry})

      {{:ok, pause_request_id}, pause_pending_state} =
        PauseResume.request_pause(state, entry, entry.issue, :ci_wait)

      assert_receive {:pause_agent, ^pause_request_id, 101}
      assert pause_pending_state.running[issue_id].control.status == :working

      assert {{:ok, :resumed}, resume_pending_state} = PauseResume.resume_issue(pause_pending_state, issue_id)
      assert_receive {:resume_agent, resume_request_id, 101}

      assert %{status: :rejected, rejection: %{class: :superseded}} =
               resume_pending_state.control_lifecycle.records[pause_request_id]

      assert {:noreply, ^resume_pending_state} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :paused, %{request_id: pause_request_id, generation: 101}},
                 resume_pending_state
               )

      assert {:noreply, resumed_state} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :working, %{request_id: resume_request_id, generation: 101}},
                 resume_pending_state
               )

      assert resumed_state.running[issue_id].control.status == :working
      refute Map.has_key?(resumed_state.running[issue_id], :pending_pause_reason)
    end

    test "a new pause supersedes an accepted resume before its worker evidence" do
      issue_id = unique_id("control-pause-pending-resume")

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
      assert {:reply, {:ok, 73}, resume_pending_state} = PauseResume.request_control_call(state, issue_id, :resume, 73)
      assert_receive {:resume_agent, 73, 101}

      assert {{:ok, pause_request_id}, paused_state} =
               PauseResume.request_pause(resume_pending_state, entry, entry.issue, :ci_wait)

      assert pause_request_id != 73
      assert_receive {:pause_agent, ^pause_request_id, 101}

      assert paused_state.running[issue_id].control.status == :paused
      assert paused_state.running[issue_id].paused_reason == :operator_pause

      assert paused_state.running[issue_id].pending_pause_reason == %{
               request_id: pause_request_id,
               reason: :ci_wait
             }

      assert %{status: :rejected, rejection: %{class: :superseded}} =
               paused_state.control_lifecycle.records[73]

      assert {:noreply, ^paused_state} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :working, %{request_id: 73, generation: 101}},
                 paused_state
               )

      assert {:noreply, applied_pause_state} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :paused, %{request_id: pause_request_id, generation: 101}},
                 paused_state
               )

      assert applied_pause_state.running[issue_id].control.status == :paused
      assert applied_pause_state.running[issue_id].paused_reason == :ci_wait
      refute Map.has_key?(applied_pause_state.running[issue_id], :pending_pause_reason)
    end

    test "a newer request publishes the older pending request as superseded" do
      issue_id = unique_id("control-superseded-event")
      state = base_state(running: %{issue_id => running_entry(issue_id)})
      :ok = AgentPubSub.subscribe_agent(issue_id)

      assert {:reply, {:ok, 70}, first_state} = PauseResume.request_control_call(state, issue_id, :pause, 70)
      assert_receive {:control_lifecycle, %{request_id: 70, status: :requested}}
      assert_receive {:control_lifecycle, %{request_id: 70, status: :accepted}}
      assert_receive {:pause_agent, 70, 101}

      assert {:reply, {:ok, 71}, _next_state} = PauseResume.request_control_call(first_state, issue_id, :pause, 71)
      assert_receive {:control_lifecycle, %{request_id: 70, status: :rejected, rejection: %{class: :superseded}}}
      assert_receive {:control_lifecycle, %{request_id: 71, status: :requested}}
      assert_receive {:control_lifecycle, %{request_id: 71, status: :accepted}}
      assert_receive {:pause_agent, 71, 101}
    end

    test "request-only controls are visibly rejected and never routed as applied" do
      issue_id = unique_id("control-request-only")

      entry =
        running_entry(issue_id,
          control: %{
            status: :working,
            can_interrupt: true,
            safe_checkpoints: [:notification],
            application_confirmation: :request_only,
            generation: 101,
            version: 0
          }
        )

      state = base_state(running: %{issue_id => entry})

      assert {:reply, {:error, {:control_rejected, %{class: :unsupported}}}, rejected_state} =
               PauseResume.request_control_call(state, issue_id, :pause, 43)

      assert %{status: :rejected, rejection: %{class: :unsupported}} =
               rejected_state.control_lifecycle.records[43]

      refute_receive {:pause_agent, 43, _generation}

      assert {:reply, {:error, {:control_rejected, %{class: :unsupported}}}, ^rejected_state} =
               PauseResume.request_control_call(rejected_state, issue_id, :pause, 43)
    end

    test "a request for the current state has a structured already-in-state rejection" do
      issue_id = unique_id("control-already-paused")

      entry =
        running_entry(issue_id,
          control: %{
            status: :paused,
            can_interrupt: true,
            safe_checkpoints: [:notification],
            application_confirmation: :confirmed,
            generation: 101,
            version: 2
          }
        )

      state = base_state(running: %{issue_id => entry})

      assert {:reply, {:error, {:control_rejected, %{class: :already_in_state}}}, rejected_state} =
               PauseResume.request_control_call(state, issue_id, :pause, 44)

      assert %{status: :rejected, rejection: %{class: :already_in_state}} =
               rejected_state.control_lifecycle.records[44]

      refute_receive {:pause_agent, 44, _generation}
    end

    test "an explicit resume request cannot bypass the existing capacity limit" do
      active_issue_id = unique_id("control-active-capacity")
      paused_issue_id = unique_id("control-paused-capacity")

      paused_entry =
        running_entry(paused_issue_id,
          control: %{
            status: :paused,
            can_interrupt: true,
            safe_checkpoints: [:notification],
            application_confirmation: :confirmed,
            generation: 101,
            version: 0
          }
        )

      state =
        base_state(
          max_concurrent_agents: 1,
          running: %{
            active_issue_id => running_entry(active_issue_id),
            paused_issue_id => paused_entry
          }
        )

      assert {:reply, {:error, :max_concurrent_agents_reached}, ^state} =
               PauseResume.request_control_call(state, paused_issue_id, :resume, 46)

      refute_receive {:resume_agent, 46, _generation}
    end

    test "worker completion expires a pending control instead of leaving it applied or pending" do
      issue_id = unique_id("control-completion-race")
      state = base_state(running: %{issue_id => running_entry(issue_id)})

      {{:ok, request_id}, accepted_state} = PauseResume.pause_agent_reply(state, issue_id)
      assert_receive {:pause_agent, ^request_id, _generation}

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
      assert_receive {:pause_agent, ^request_id, generation}

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

      assert rejected_state.running[issue_id] == changed_state.running[issue_id]

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
      assert_receive {:resume_agent, request_id, 101}

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
      assert_receive {:resume_agent, 45, 101}

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

        assert_receive {:resume_agent, ^request_id, 101}

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
      assert_receive {:pause_agent, label_request_id, 101}
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

      assert_receive {:pause_agent, duration_request_id, 101}
      assert duration_pending_state.running[issue_id].control.status == :working

      assert duration_pending_state.running[issue_id].pending_pause_reason == %{
               request_id: duration_request_id,
               reason: :max_agent_duration
             }

      agent_pending_state = PushRouting.maybe_pause_on_request(state, issue_id)
      assert_receive {:pause_agent, agent_request_id, 101}
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
      assert_receive {:tick, _token}
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
      assert_receive {:resume_agent, _request_id}
      assert_receive {:tick, _token}
    end
  end

  describe ":DOWN routing" do
    test "a stale monitor ref leaves all orchestrator state untouched" do
      issue_id = unique_id("down-stale")
      state = base_state(running: %{issue_id => running_entry(issue_id)})

      assert {:noreply, ^state} =
               Orchestrator.handle_info(
                 {:DOWN, make_ref(), :process, self(), :normal},
                 state
               )
    end

    test "a real completed child exiting normally parks its identity without a retry" do
      issue_id = unique_id("down-completed")
      {:ok, worker} = supervised_worker()
      monitor_ref = Process.monitor(worker)

      entry =
        running_entry(issue_id,
          pid: worker,
          ref: monitor_ref,
          worker_host: "worker-a",
          workspace_path: "/workspace/#{issue_id}",
          control: %{status: :completed, can_interrupt: true}
        )

      state =
        base_state(
          running: %{issue_id => entry},
          claimed: MapSet.new([issue_id]),
          retry_attempts: %{issue_id => %{attempt: 4}}
        )

      send(worker, :stop)
      assert_receive {:DOWN, ^monitor_ref, :process, ^worker, :normal}, 1_000

      assert {:noreply, next} =
               Orchestrator.handle_info(
                 {:DOWN, monitor_ref, :process, worker, :normal},
                 state
               )

      parked = Map.fetch!(next.running, issue_id)
      assert parked.pid == nil
      assert parked.ref == nil
      assert parked.control.status == :completed
      assert parked.session_id == entry.session_id
      assert parked.worker_host == "worker-a"
      assert parked.workspace_path == "/workspace/#{issue_id}"
      assert MapSet.member?(next.claimed, issue_id)
      assert MapSet.member?(next.completed, issue_id)
      refute Map.has_key?(next.retry_attempts, issue_id)

      assert {:noreply, ^next} =
               Orchestrator.handle_info(
                 {:DOWN, monitor_ref, :process, worker, :normal},
                 next
               )
    end

    test "a real pre-completion child exiting abnormally schedules a failure retry" do
      issue_id = unique_id("down-real-crash")
      {:ok, worker} = supervised_worker()
      monitor_ref = Process.monitor(worker)

      entry =
        running_entry(issue_id,
          pid: worker,
          ref: monitor_ref,
          retry_attempt: 1,
          control: %{
            status: :working,
            can_interrupt: true,
            safe_checkpoints: [:notification],
            application_confirmation: :confirmed,
            generation: 101,
            version: 0
          }
        )

      state = base_state(running: %{issue_id => entry}, claimed: MapSet.new([issue_id]))

      {{:ok, request_id}, accepted_state} = PauseResume.pause_agent_reply(state, issue_id)
      assert %{status: :accepted} = accepted_state.control_lifecycle.records[request_id]

      Process.exit(worker, :boom)
      assert_receive {:DOWN, ^monitor_ref, :process, ^worker, :boom}, 1_000

      assert {:noreply, next} =
               Orchestrator.handle_info(
                 {:DOWN, monitor_ref, :process, worker, :boom},
                 accepted_state
               )

      refute Map.has_key?(next.running, issue_id)
      assert %{attempt: 2, error: "agent exited: :boom"} = next.retry_attempts[issue_id]
      assert %{status: :expired, expiry: %{reason: :worker_unavailable}} = next.control_lifecycle.records[request_id]
      cancel_retry_timer(next.retry_attempts[issue_id])
    end

    test "normal exit completes and schedules continuation without teardown" do
      issue_id = unique_id("down-normal")
      {worker, workspace, marker} = live_worker_workspace(issue_id)
      monitor_ref = make_ref()
      started_at = DateTime.add(DateTime.utc_now(), -5, :second)

      entry =
        running_entry(issue_id,
          pid: worker,
          ref: monitor_ref,
          started_at: started_at,
          retry_attempt: 7,
          worker_host: "worker-a",
          workspace_path: workspace
        )

      state =
        base_state(
          running: %{issue_id => entry},
          claimed: MapSet.new([issue_id]),
          retry_attempts: %{issue_id => %{attempt: 7}},
          agent_totals: %{
            input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            seconds_running: 3
          }
        )

      before_down = DateTime.utc_now()

      assert {:noreply, next} =
               Orchestrator.handle_info(
                 {:DOWN, monitor_ref, :process, worker, :normal},
                 state
               )

      after_down = DateTime.utc_now()
      refute Map.has_key?(next.running, issue_id)
      assert MapSet.member?(next.completed, issue_id)
      assert MapSet.member?(next.claimed, issue_id)

      earliest_total = 3 + DateTime.diff(before_down, started_at, :second)
      latest_total = 3 + DateTime.diff(after_down, started_at, :second)
      assert next.agent_totals.seconds_running in earliest_total..latest_total

      assert %{
               attempt: 1,
               identifier: ^issue_id,
               error: nil,
               retry_poll_failures: 0,
               worker_host: "worker-a",
               workspace_path: ^workspace,
               retry_token: retry_token,
               timer_ref: timer_ref
             } = next.retry_attempts[issue_id]

      assert is_reference(retry_token)
      assert is_reference(timer_ref)
      assert Process.alive?(worker)
      assert File.exists?(marker)

      cancel_retry_timer(next.retry_attempts[issue_id])
    end

    test "abnormal exit schedules the next failure attempt without teardown" do
      issue_id = unique_id("down-crash")
      {worker, workspace, marker} = live_worker_workspace(issue_id)
      monitor_ref = make_ref()
      started_at = DateTime.add(DateTime.utc_now(), -5, :second)

      entry =
        running_entry(issue_id,
          pid: worker,
          ref: monitor_ref,
          started_at: started_at,
          retry_attempt: 2,
          worker_host: "worker-b",
          workspace_path: workspace
        )

      state =
        base_state(
          running: %{issue_id => entry},
          claimed: MapSet.new([issue_id]),
          completed: MapSet.new(["already-complete"]),
          agent_totals: %{
            input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            seconds_running: 2
          }
        )

      before_down = DateTime.utc_now()

      assert {:noreply, next} =
               Orchestrator.handle_info(
                 {:DOWN, monitor_ref, :process, worker, :boom},
                 state
               )

      after_down = DateTime.utc_now()
      refute Map.has_key?(next.running, issue_id)
      refute MapSet.member?(next.completed, issue_id)
      assert next.completed == MapSet.new(["already-complete"])
      assert MapSet.member?(next.claimed, issue_id)

      earliest_total = 2 + DateTime.diff(before_down, started_at, :second)
      latest_total = 2 + DateTime.diff(after_down, started_at, :second)
      assert next.agent_totals.seconds_running in earliest_total..latest_total

      assert %{
               attempt: 3,
               identifier: ^issue_id,
               error: "agent exited: :boom",
               retry_poll_failures: 0,
               worker_host: "worker-b",
               workspace_path: ^workspace,
               retry_token: retry_token,
               timer_ref: timer_ref
             } = next.retry_attempts[issue_id]

      assert is_reference(retry_token)
      assert is_reference(timer_ref)
      assert Process.alive?(worker)
      assert File.exists?(marker)

      cancel_retry_timer(next.retry_attempts[issue_id])
    end
  end

  defp base_state(attrs) do
    struct!(
      State,
      Keyword.merge(
        [
          running: %{},
          claimed: MapSet.new(),
          completed: MapSet.new(),
          retry_attempts: %{},
          max_concurrent_agents: 6,
          agent_totals: nil,
          codex_totals: %{
            input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            seconds_running: 0
          }
        ],
        attrs
      )
    )
  end

  defp running_entry(issue_id, attrs \\ []) do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: issue_id,
      issue: %Issue{
        id: issue_id,
        identifier: issue_id,
        state: "in-progress",
        title: "Characterize control routing",
        tracker_identity: tracker_identity(issue_id)
      },
      control: %{
        status: :working,
        can_interrupt: true,
        safe_checkpoints: [:notification],
        application_confirmation: :confirmed,
        generation: 101,
        version: 0
      },
      session_id: "thread-#{issue_id}",
      started_at: DateTime.utc_now()
    }
    |> Map.merge(Map.new(attrs))
  end

  defp live_worker_workspace(issue_id) do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "aiur_control_routing_#{issue_id}_#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    marker = Path.join(workspace, "must-survive")
    File.mkdir_p!(workspace)
    File.write!(marker, "present")
    worker = spawn(fn -> receive do: (:stop -> :ok) end)

    on_exit(fn ->
      if Process.alive?(worker), do: Process.exit(worker, :kill)
      File.rm_rf(workspace)
    end)

    {worker, workspace, marker}
  end

  defp supervised_worker do
    Task.Supervisor.start_child(Aiur.TaskSupervisor, fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp cancel_retry_timer(%{timer_ref: timer_ref, retry_token: retry_token}) do
    Process.cancel_timer(timer_ref)

    receive do
      {:retry_issue, _issue_id, ^retry_token} -> :ok
    after
      0 -> :ok
    end
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp tracker_identity(identifier) do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "its-everdred",
      repository: "aiur",
      provider_id: "I_kwDO#{identifier}",
      identifier: "101",
      reason: nil
    }
  end
end
