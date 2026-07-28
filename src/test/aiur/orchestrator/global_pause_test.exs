defmodule Aiur.Orchestrator.GlobalPauseTest do
  use Aiur.TestSupport

  alias Aiur.{Issue, TrackerIdentity}
  alias Aiur.Orchestrator.{GlobalPause, PauseResume, State}

  describe "set_global_pause_call/2 pause" do
    test "holds every working agent and tags them global_pause without overriding an individual pause" do
      individual = unique_id("gp-individual")
      free = unique_id("gp-free")

      state =
        base_state(
          running: %{
            individual => running_entry(individual),
            free => running_entry(free)
          }
        )

      # An operator individually pauses one agent first.
      state = apply_pause(state, individual, :operator_pause)
      assert state.running[individual].control.status == :paused
      assert state.running[individual].paused_reason == :operator_pause

      # Global pause: the individually paused agent is skipped; the free one is held.
      {:reply, {:ok, %{globally_paused: true}}, paused_state} =
        GlobalPause.set_global_pause_call(state, true)

      assert paused_state.globally_paused
      # No new control request is routed to the already-paused agent.
      refute_receive {:pause_agent, _rid, _gen, _id_extra}, 50
      assert paused_state.running[individual].paused_reason == :operator_pause

      # The free agent received a global-pause hold request.
      assert %{reason: :global_pause} = paused_state.running[free].pending_pause_reason
      assert_receive {:pause_agent, free_rid, 101}

      applied_state = apply_worker_pause(paused_state, free, free_rid, :global_pause)
      assert applied_state.running[free].control.status == :paused
      assert applied_state.running[free].paused_reason == :global_pause
      # Individual pause is untouched throughout.
      assert applied_state.running[individual].paused_reason == :operator_pause
    end
  end

  describe "set_global_pause_call/2 unpause" do
    test "resumes only globally held agents and leaves individually paused agents paused" do
      individual = unique_id("gp-keep")
      held = unique_id("gp-held")

      state =
        base_state(
          globally_paused: true,
          running: %{
            individual => paused_entry(individual, :operator_pause),
            held => paused_entry(held, :global_pause)
          }
        )

      {:reply, {:ok, %{globally_paused: false}}, resumed_state} =
        GlobalPause.set_global_pause_call(state, false)

      refute resumed_state.globally_paused

      # Only the globally held agent gets a resume request.
      assert_receive {:resume_agent, held_rid, 101}
      refute_receive {:resume_agent, _rid, _gen}, 50

      # The individually paused agent is never touched.
      assert resumed_state.running[individual].control.status == :paused
      assert resumed_state.running[individual].paused_reason == :operator_pause

      # Applying the worker's resume evidence clears the global-pause marker.
      applied_state = apply_worker_resume(resumed_state, held, held_rid)
      refute Map.has_key?(applied_state.running[held], :paused_reason)
      assert applied_state.running[individual].paused_reason == :operator_pause
    end
  end

  describe "global-hold-wins guard" do
    test "an individual resume is blocked while globally paused" do
      id = unique_id("gp-guard")
      state = base_state(globally_paused: true, running: %{id => paused_entry(id, :global_pause)})

      assert {:reply, {:error, :globally_paused}, ^state} =
               PauseResume.resume_issue_call(state, id)

      assert {:reply, {:error, :globally_paused}, ^state} =
               PauseResume.request_control_call(state, id, :resume, 7)

      refute_receive {:resume_agent, _rid, _gen}, 50
    end

    test "an individual pause still passes through while globally paused" do
      id = unique_id("gp-guard-pause")

      state =
        base_state(globally_paused: true, running: %{id => running_entry(id)})

      assert {:reply, {:ok, 8}, _state} =
               PauseResume.request_control_call(state, id, :pause, 8)

      assert_receive {:pause_agent, 8, 101}
    end
  end

  describe "idempotency and projection" do
    test "re-pausing or re-unpausing is a no-op" do
      already_paused = base_state(globally_paused: true, running: %{})

      assert {:reply, {:ok, %{globally_paused: true}}, ^already_paused} =
               GlobalPause.set_global_pause_call(already_paused, true)

      already_running = base_state(globally_paused: false, running: %{})

      assert {:reply, {:ok, %{globally_paused: false}}, ^already_running} =
               GlobalPause.set_global_pause_call(already_running, false)
    end

    test "globally_paused_call and global_pause_status mirror the flag" do
      state = base_state(globally_paused: true, running: %{})

      assert {:reply, true, ^state} = GlobalPause.globally_paused_call(state)
      assert GlobalPause.global_pause_status(state) == %{globally_paused: true}

      assert GlobalPause.global_pause_status(%{state | globally_paused: false}) ==
               %{globally_paused: false}
    end
  end

  # Route a per-agent pause and apply the worker's confirming evidence.
  defp apply_pause(state, issue_id, reason) do
    {{:ok, _request_id}, pending} =
      PauseResume.request_pause(state, state.running[issue_id], state.running[issue_id].issue, reason)

    assert_receive {:pause_agent, request_id, 101}
    apply_worker_pause(pending, issue_id, request_id, reason)
  end

  defp apply_worker_pause(state, issue_id, request_id, kind) do
    {:noreply, applied} =
      Aiur.Orchestrator.handle_info(
        {:worker_control_state, issue_id, :paused, %{request_id: request_id, generation: 101, kind: kind}},
        state
      )

    applied
  end

  defp apply_worker_resume(state, issue_id, request_id) do
    {:noreply, applied} =
      Aiur.Orchestrator.handle_info(
        {:worker_control_state, issue_id, :working, %{request_id: request_id, generation: 101}},
        state
      )

    applied
  end

  defp paused_entry(issue_id, reason) do
    running_entry(issue_id,
      control: %{
        status: :paused,
        can_interrupt: true,
        safe_checkpoints: [:notification],
        application_confirmation: :confirmed,
        generation: 101,
        version: 1
      },
      paused_reason: reason
    )
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
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
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
        title: "Global pause switch",
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
