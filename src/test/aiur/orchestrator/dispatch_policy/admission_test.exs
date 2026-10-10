defmodule Aiur.Orchestrator.DispatchPolicy.AdmissionTest do
  use Aiur.TestSupport

  alias Aiur.{ModelAvailability, Workflow}
  alias Aiur.Orchestrator.{DispatchPolicy, Slots, State}

  describe "run_queue_gate/3" do
    test "holds only when runnable strictly exceeds the per-scheduler threshold" do
      assert DispatchPolicy.run_queue_gate(19, 12, 1.5) == :hold
      assert DispatchPolicy.run_queue_gate(18, 12, 1.5) == :dispatch
      assert DispatchPolicy.run_queue_gate(12, 12, 1.0) == :dispatch
      assert DispatchPolicy.run_queue_gate(13, 12, 1.0) == :hold
    end

    test "fails open when disabled, non-numeric, or the sample is unavailable" do
      assert DispatchPolicy.run_queue_gate(99, 12, nil) == :dispatch
      assert DispatchPolicy.run_queue_gate(99, 12, 0.0) == :dispatch
      assert DispatchPolicy.run_queue_gate(99, 12, -1.0) == :dispatch
      assert DispatchPolicy.run_queue_gate(99, 12, :invalid) == :dispatch
      assert DispatchPolicy.run_queue_gate(:unavailable, 12, 1.5) == :dispatch
    end

    test "admission ignores a niced runnable queue when CPU remains reclaimable" do
      assert :dispatch =
               DispatchPolicy.admission_gate(
                 gate_input(%{
                   run_queue_threshold: 1.5,
                   runnable: 74,
                   load: 10.0,
                   cpu_headroom: %{
                     idle_percent: 10.0,
                     nice_percent: 70.0,
                     reclaimable_percent: 80.0,
                     runnable: 74
                   }
                 })
               )
    end
  end

  describe "admission_gate/1" do
    defp gate_input(overrides) do
      Map.merge(
        %{
          memory_mb: 4_096,
          memory_threshold_mb: 2_048,
          fd_sample: %{used: 50, limit: 100, available: 50, headroom_ratio: 0.5},
          runnable: 10,
          run_queue_threshold: nil,
          schedulers: 12,
          load: 10.0,
          load_threshold: 1.5,
          build_status: %{enabled?: false, capacity: 0, active: 0, queued: 0},
          provider_backends: [],
          github_quota: :available,
          # A measured window with no reclaimable CPU: the load and run-queue
          # gates need one before they can hold at all (#2089).
          cpu_headroom: %{idle_percent: 5.0, nice_percent: 0.0, reclaimable_percent: 5.0, runnable: 20},
          queued_demand?: true
        },
        overrides
      )
    end

    test "dispatches when every signal is within threshold" do
      assert DispatchPolicy.admission_gate(gate_input(%{})) == :dispatch
    end

    test "reports the highest-priority binding signal with measured value and threshold" do
      assert {:hold, %{signal: :memory, measured: 1_024, threshold: 2_048}} =
               DispatchPolicy.admission_gate(gate_input(%{memory_mb: 1_024, fd_sample: :exhausted, runnable: 99, load: 99.0}))

      assert {:hold, %{signal: :file_descriptors}} =
               DispatchPolicy.admission_gate(gate_input(%{fd_sample: %{used: 91, limit: 100, available: 9, headroom_ratio: 0.09}}))

      assert {:hold, %{signal: :run_queue, measured: 20, threshold: 18.0}} =
               DispatchPolicy.admission_gate(gate_input(%{run_queue_threshold: 1.5, runnable: 20}))

      assert {:hold, %{signal: :load, measured: 25.0, threshold: 18.0}} =
               DispatchPolicy.admission_gate(gate_input(%{load: 25.0}))

      assert :dispatch =
               DispatchPolicy.admission_gate(
                 gate_input(%{
                   load: 143.0,
                   cpu_headroom: %{idle_percent: 10.0, nice_percent: 70.0, reclaimable_percent: 80.0, runnable: 74}
                 })
               )

      reset_at = ~U[2026-08-09 22:00:00Z]
      observed_at = ~U[2026-08-09 21:55:00Z]

      assert {:hold,
              %{
                signal: :github_quota,
                measured: %{resource: "core", observed_at: ^observed_at},
                threshold: :ten_percent_remaining
              }} =
               DispatchPolicy.admission_gate(
                 gate_input(%{
                   github_quota:
                     {:hold,
                      %{
                        resource: "core",
                        remaining: 500,
                        limit: 5000,
                        reset_at: reset_at,
                        observed_at: observed_at
                      }}
                 })
               )

      build = %{enabled?: true, capacity: 1, active: 1, queued: 1}

      assert {:hold, %{signal: :github_quota}} =
               DispatchPolicy.admission_gate(
                 gate_input(%{
                   github_quota: {:hold, %{resource: "graphql"}},
                   run_queue_threshold: 1.0,
                   runnable: 99,
                   load: 99.0,
                   build_status: build
                 })
               )
    end

    test "reports build pressure and provider limits in priority order" do
      build = %{enabled?: true, capacity: 2, active: 2, queued: 1}

      assert {:hold, %{signal: :build, threshold: 2}} =
               DispatchPolicy.admission_gate(gate_input(%{build_status: build}))

      future = ~U[2099-01-01 00:00:00Z]
      :ok = ModelAvailability.mark_limited("codex", DateTime.to_iso8601(future))

      assert {:hold, %{signal: :provider, threshold: :all_usage_limited}} =
               DispatchPolicy.admission_gate(gate_input(%{provider_backends: ["codex"], queued_demand?: true}))
    end

    test "ignores the provider gate when there is no queued demand" do
      future = ~U[2099-01-01 00:00:00Z]
      :ok = ModelAvailability.mark_limited("codex", DateTime.to_iso8601(future))

      assert :dispatch ==
               DispatchPolicy.admission_gate(gate_input(%{provider_backends: ["codex"], queued_demand?: false}))
    end
  end

  describe "CPU sample continuity" do
    test "cold start widens additively despite clear CPU headroom" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 10, target_load_average: 1.0)

      baseline = %{total: 1_000, idle: 800, runnable: 1}
      current = %{total: 1_200, idle: 960, runnable: 1}

      state = %State{
        max_concurrent_agents: 10,
        effective_concurrent_agents: 1,
        load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: nil}
      }

      seeded = DispatchPolicy.update_load_envelope(state, 0.0, 1.0, 16, 1_000, baseline, true)
      assert seeded.effective_concurrent_agents == 1
      assert seeded.load_envelope_state.last_decrease_ms == nil
      assert seeded.load_envelope_state.bootstrap_complete?

      ramped = DispatchPolicy.update_load_envelope(seeded, 0.0, 1.0, 16, 2_000, current, true)
      assert ramped.effective_concurrent_agents == 2
      assert ramped.load_envelope_state.last_decrease_ms == nil
      assert ramped.load_envelope_state.bootstrap_complete?
    end

    test "cold start cannot widen above target despite niced headroom" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 8, target_load_average: 1.0)

      previous = %{total: 1_000, idle: 600, nice: 100, background: %{epoch: :e, daemon_nice: 0, ticks: 100, cpu_total: 1_000}, runnable: 20}
      current = %{total: 1_200, idle: 620, nice: 240, background: %{epoch: :e, daemon_nice: 0, ticks: 240, cpu_total: 1_200}, runnable: 74}

      state = %State{
        max_concurrent_agents: 8,
        effective_concurrent_agents: 1,
        load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: previous}
      }

      seeded = DispatchPolicy.update_load_envelope(state, 143.0, 1.0, 16, 2_000, current, true)

      assert seeded.effective_concurrent_agents == 1
      assert seeded.load_envelope_state.bootstrap_complete?
    end

    test "cold start does not add host-sized headroom to occupied slots" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 20, target_load_average: 1.0)

      previous = %{total: 1_000, idle: 800, runnable: 1}
      current = %{total: 1_200, idle: 950, runnable: 1}

      state = %State{
        max_concurrent_agents: 20,
        effective_concurrent_agents: 8,
        load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: previous},
        running: %{
          "active" => %{control: %{status: :working}},
          "operator-paused" => %{control: %{status: :paused}, paused_reason: :operator_pause},
          "ci-wait" => %{control: %{status: :paused}, paused_reason: :ci_wait}
        }
      }

      seeded = DispatchPolicy.update_load_envelope(state, 0.0, 1.0, 16, 2_000, current, true)

      assert seeded.effective_concurrent_agents == 9
      assert Slots.available_slots(seeded) == 7
      assert seeded.load_envelope_state.bootstrap_complete?
    end

    test "additive ramp never shrinks a warmed envelope on consecutive samples" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 20, target_load_average: 1.0)

      previous = %{total: 1_000, idle: 800, runnable: 1}
      current = %{total: 1_200, idle: 925, runnable: 1}
      next = %{total: 1_400, idle: 1_050, runnable: 1}

      state = %State{
        max_concurrent_agents: 20,
        effective_concurrent_agents: 20,
        load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: previous},
        running: %{"active" => %{control: %{status: :working}}}
      }

      seeded = DispatchPolicy.update_load_envelope(state, 0.0, 1.0, 16, 2_000, current, true)
      steady = DispatchPolicy.update_load_envelope(seeded, 0.0, 1.0, 16, 3_000, next, true)

      assert seeded.effective_concurrent_agents == 20
      assert steady.effective_concurrent_agents == 20
      assert seeded.load_envelope_state.bootstrap_complete?
      assert steady.load_envelope_state.bootstrap_complete?
    end

    test "an unavailable sample clears the baseline before recovery can fast-ramp" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 8, target_load_average: 1.0)

      previous = %{total: 1_000, idle: 800, runnable: 1}
      current = %{total: 1_200, idle: 960, runnable: 1}

      state = %State{
        max_concurrent_agents: 8,
        effective_concurrent_agents: 4,
        load_envelope_state: %{last_decrease_ms: 1_000, cpu_snapshot: previous}
      }

      unavailable = DispatchPolicy.update_load_envelope(state, 0.0, 1.0, 8, 2_000, :unavailable, true)
      assert unavailable.effective_concurrent_agents == 5
      assert unavailable.load_envelope_state.cpu_snapshot == nil

      reseeded = DispatchPolicy.update_load_envelope(unavailable, 0.0, 1.0, 8, 3_000, current, true)
      assert reseeded.effective_concurrent_agents == 6
      assert reseeded.load_envelope_state.cpu_snapshot == current

      disabled = DispatchPolicy.update_load_envelope(state, 99.0, nil, 8, 2_000, :unavailable, true)
      assert disabled.effective_concurrent_agents == 8
      assert disabled.load_envelope_state.cpu_snapshot == nil
    end
  end
end
