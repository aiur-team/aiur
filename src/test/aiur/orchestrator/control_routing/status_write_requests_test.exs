Code.require_file("../../../support/control_routing_fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.ControlRouting.StatusWriteRequestsTest do
  use Aiur.TestSupport

  import Aiur.TestSupport.ControlRoutingFixture

  alias Aiur.AgentPubSub
  alias Aiur.Orchestrator.{ControlLifecycle, PauseResume}

  describe "control-status writes" do
    test "accepted pause stays working until matching worker evidence applies it" do
      issue_id = unique_id("control-correlated-pause")
      entry = running_entry(issue_id)
      state = base_state(running: %{issue_id => entry})

      {{:ok, request_id}, accepted_state} = PauseResume.pause_agent_reply(state, issue_id)

      assert accepted_state.running[issue_id].control.status == :working
      assert accepted_state.control_lifecycle.pending[issue_id] == request_id
      assert %{request_id: ^request_id, status: :accepted} = accepted_state.control_lifecycle.records[request_id]
      assert_receive {:pause_agent, ^request_id, generation}, 1000

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

      # Rejection changes nothing but the rejected request's own pending
      # pause reason, which must not outlive the request (#2730).
      assert %{reason: :operator_pause} = replacement_state.running[issue_id].pending_pause_reason
      refute Map.has_key?(stale_generation_state.running[issue_id], :pending_pause_reason)
      assert stale_generation_state.running[issue_id] == Map.delete(replacement_state.running[issue_id], :pending_pause_reason)

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

      assert_receive {:pause_agent, ^request_id, 101}, 1000
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

      assert_receive {:pause_agent, 42, 101}, 1000

      assert {:reply, {:ok, 42}, ^accepted_state} =
               PauseResume.request_control_call(accepted_state, issue_id, :pause, 42)

      refute_receive {:pause_agent, 42, _generation}, 100

      assert [%{request_id: 42, status: :accepted}] =
               ControlLifecycle.history(accepted_state.control_lifecycle, issue_id)
    end

    test "resume supersedes a pending pause and the stale pause cannot apply later" do
      issue_id = unique_id("control-resume-pending-pause")
      entry = running_entry(issue_id)
      state = base_state(running: %{issue_id => entry})

      {{:ok, pause_request_id}, pause_pending_state} =
        PauseResume.request_pause(state, entry, entry.issue, :ci_wait)

      assert_receive {:pause_agent, ^pause_request_id, 101}, 1000
      assert pause_pending_state.running[issue_id].control.status == :working

      assert {{:ok, :resumed}, resume_pending_state} = PauseResume.resume_issue(pause_pending_state, issue_id)
      assert_receive {:resume_agent, resume_request_id, 101}, 1000

      assert %{status: :rejected, rejection: %{class: :superseded}} =
               resume_pending_state.control_lifecycle.records[pause_request_id]

      assert {:noreply, unclassified_pause_state} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :paused, %{kind: :worker_pause_unknown}},
                 resume_pending_state
               )

      assert unclassified_pause_state.running[issue_id].paused_reason == :worker_pause_unknown

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

    test "an uncorrelated worker pause does not inherit a pending operator cause" do
      issue_id = unique_id("control-uncorrelated-operator-pause")
      entry = running_entry(issue_id)
      state = base_state(running: %{issue_id => entry})

      assert {{:ok, request_id}, pause_pending_state} =
               PauseResume.request_pause(state, entry, entry.issue, :operator_pause)

      assert_receive {:pause_agent, ^request_id, 101}, 1000

      assert {:noreply, unclassified_pause_state} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :paused, %{kind: :worker_pause_unknown}},
                 pause_pending_state
               )

      assert unclassified_pause_state.running[issue_id].paused_reason == :worker_pause_unknown
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
      assert_receive {:resume_agent, 73, 101}, 1000

      assert {{:ok, pause_request_id}, paused_state} =
               PauseResume.request_pause(resume_pending_state, entry, entry.issue, :ci_wait)

      assert pause_request_id != 73
      assert_receive {:pause_agent, ^pause_request_id, 101}, 1000

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
      assert_receive {:control_lifecycle, %{request_id: 70, status: :requested}}, 1000
      assert_receive {:control_lifecycle, %{request_id: 70, status: :accepted}}, 1000
      assert_receive {:pause_agent, 70, 101}, 1000

      assert {:reply, {:ok, 71}, _next_state} = PauseResume.request_control_call(first_state, issue_id, :pause, 71)
      assert_receive {:control_lifecycle, %{request_id: 70, status: :rejected, rejection: %{class: :superseded}}}, 1000
      assert_receive {:control_lifecycle, %{request_id: 71, status: :requested}}, 1000
      assert_receive {:control_lifecycle, %{request_id: 71, status: :accepted}}, 1000
      assert_receive {:pause_agent, 71, 101}, 1000
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

      refute_receive {:pause_agent, 43, _generation}, 100

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

      refute_receive {:pause_agent, 44, _generation}, 100
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

      refute_receive {:resume_agent, 46, _generation}, 100
    end
  end
end
