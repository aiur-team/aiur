defmodule Aiur.Orchestrator.DispatchPolicyTest do
  use Aiur.TestSupport

  alias Aiur.{Issue, ModelAvailability, Workflow}
  alias Aiur.Orchestrator.{DispatchPolicy, Slots, State}

  describe "load_gate/3" do
    test "matches the load gate truth table" do
      assert DispatchPolicy.load_gate(20.0, 1.5, 12) == :hold
      assert DispatchPolicy.load_gate(10.0, 1.5, 12) == :dispatch
      assert DispatchPolicy.load_gate(18.0, 1.5, 12) == :dispatch
      assert DispatchPolicy.load_gate(99.0, nil, 12) == :dispatch
      assert DispatchPolicy.load_gate(99.0, 0.0, 12) == :dispatch
      assert DispatchPolicy.load_gate(99.0, -1.0, 12) == :dispatch
      assert DispatchPolicy.load_gate(:unavailable, 1.5, 12) == :dispatch
    end
  end

  describe "prewarm_gate/2" do
    test "matches the prewarm gate truth table" do
      assert DispatchPolicy.prewarm_gate(false, :building) == :dispatch
      assert DispatchPolicy.prewarm_gate(false, :idle) == :dispatch
      assert DispatchPolicy.prewarm_gate(false, {:error, :boom}) == :dispatch
      assert DispatchPolicy.prewarm_gate(true, :ready) == :dispatch
      assert DispatchPolicy.prewarm_gate(true, {:error, :base_build_failed}) == :dispatch
      assert DispatchPolicy.prewarm_gate(true, :building) == :hold
    end
  end

  describe "read_load/1" do
    test "returns unavailable when the threshold is disabled" do
      assert DispatchPolicy.read_load(nil) == :unavailable
      assert DispatchPolicy.read_load(0) == :unavailable
      assert DispatchPolicy.read_load(-1) == :unavailable
    end
  end

  describe "read_cpu/1" do
    test "does not touch procfs when the adaptive envelope is disabled" do
      Application.put_env(:aiur, :proc_stat_source_override, fn ->
        flunk("/proc/stat must not be read when the envelope is disabled")
      end)

      on_exit(fn -> Application.delete_env(:aiur, :proc_stat_source_override) end)

      assert DispatchPolicy.read_cpu(nil) == :unavailable
      assert DispatchPolicy.read_cpu(0) == :unavailable
    end

    test "reads the CPU snapshot when the run-queue gate is enabled even with the envelope disabled" do
      Application.put_env(:aiur, :proc_stat_source_override, fn ->
        {:ok, "cpu 100 0 100 800 0 0 0 0 0 0\nprocs_running 3\n"}
      end)

      on_exit(fn -> Application.delete_env(:aiur, :proc_stat_source_override) end)

      assert %{runnable: 3} = DispatchPolicy.read_cpu(nil, 1.5)
      assert DispatchPolicy.read_cpu(nil, nil) == :unavailable
      assert DispatchPolicy.read_cpu(nil, 0) == :unavailable
    end
  end

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
  end

  describe "build_gate/1" do
    test "holds while every build slot is busy or builds are queued" do
      assert DispatchPolicy.build_gate(%{enabled?: true, capacity: 2, active: 2, queued: 0}) == :hold
      assert DispatchPolicy.build_gate(%{enabled?: true, capacity: 2, active: 1, queued: 1}) == :hold
      assert DispatchPolicy.build_gate(%{enabled?: true, capacity: 2, active: 1, queued: 0}) == :dispatch
    end

    test "fails open when the gate is disabled, capacity is zero, or status is unavailable" do
      assert DispatchPolicy.build_gate(%{enabled?: false, capacity: 0, active: 0, queued: 0}) == :dispatch
      assert DispatchPolicy.build_gate(%{enabled?: true, capacity: 0, active: 0, queued: 5}) == :dispatch
      assert DispatchPolicy.build_gate(:unavailable) == :dispatch
      assert DispatchPolicy.build_gate(%{enabled?: true, degraded?: true, capacity: 2, active: 0, queued: 0}) == :dispatch
    end
  end

  describe "provider_gate/1" do
    test "holds only when every dispatchable backend is usage-limited" do
      write_workflow_file!(Workflow.workflow_file_path())
      future = ~U[2099-01-01 00:00:00Z]
      :ok = ModelAvailability.mark_limited("codex", DateTime.to_iso8601(future))

      assert DispatchPolicy.provider_gate(["codex"]) == :hold
      assert DispatchPolicy.provider_gate([]) == :dispatch
      assert DispatchPolicy.provider_gate(:unavailable) == :dispatch
    end

    test "dispatches when any dispatchable backend remains available" do
      write_workflow_file!(Workflow.workflow_file_path())
      future = ~U[2099-01-01 00:00:00Z]
      :ok = ModelAvailability.mark_limited("codex", DateTime.to_iso8601(future))

      assert DispatchPolicy.provider_gate(["codex", "claude"]) == :dispatch
    end
  end

  describe "read_build_status/0" do
    test "delegates to the injected test seam" do
      Application.put_env(:aiur, :build_gate_status_override, fn -> %{enabled?: true, capacity: 3, active: 3, queued: 0} end)
      on_exit(fn -> Application.delete_env(:aiur, :build_gate_status_override) end)

      assert %{active: 3} = DispatchPolicy.read_build_status()
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

      reset_at = ~U[2026-08-09 22:00:00Z]

      assert {:hold, %{signal: :github_quota, measured: %{resource: "core"}, threshold: :ten_percent_remaining}} =
               DispatchPolicy.admission_gate(gate_input(%{github_quota: {:hold, %{resource: "core", remaining: 500, limit: 5000, reset_at: reset_at}}}))
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

  describe "sort_issues_for_dispatch/1" do
    test "orders by priority rank, missing priority, created_at, then identifier" do
      early = ~U[2026-01-01 00:00:00Z]
      late = ~U[2026-01-02 00:00:00Z]

      issues = [
        issue("late-p1", priority: 1, created_at: late, identifier: "C"),
        issue("rank5-b", priority: 9, created_at: early, identifier: "B"),
        issue("p2", priority: 2, created_at: early, identifier: "A"),
        issue("missing-date", priority: 1, created_at: nil, identifier: "D"),
        issue("early-p1", priority: 1, created_at: early, identifier: "A"),
        issue("rank5-a", priority: nil, created_at: early, identifier: "A")
      ]

      assert Enum.map(DispatchPolicy.sort_issues_for_dispatch(issues), & &1.id) == [
               "early-p1",
               "late-p1",
               "missing-date",
               "p2",
               "rank5-a",
               "rank5-b"
             ]
    end
  end

  describe "candidate_issue?/3" do
    test "requires binary id, identifier, title, and state" do
      active_states = MapSet.new(["todo"])
      terminal_states = MapSet.new(["done"])

      assert DispatchPolicy.candidate_issue?(
               issue("valid", identifier: "repo#1", title: "work", state: "todo"),
               active_states,
               terminal_states
             )

      refute DispatchPolicy.candidate_issue?(
               issue(nil, identifier: "repo#1", title: "work", state: "todo"),
               active_states,
               terminal_states
             )

      refute DispatchPolicy.candidate_issue?(
               issue("nil-state", identifier: "repo#1", title: "work", state: nil),
               active_states,
               terminal_states
             )

      refute DispatchPolicy.candidate_issue?(
               issue("untrusted", dispatch_authorized?: false),
               active_states,
               terminal_states
             )
    end
  end

  describe "queued_dispatch_demand?/2" do
    test "finds eligible queued work independently of the current envelope slots" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 5)
      state = %State{max_concurrent_agents: 5, effective_concurrent_agents: 1}

      assert DispatchPolicy.queued_dispatch_demand?([issue("queued", [])], state)
    end

    test "a rework ticket with free capacity is dispatchable without a manual resume" do
      # #1453 acceptance: a ticket flipped to agent:rework dispatches within one
      # poll cycle — rework is an active state, so the dispatcher treats it as
      # ready work at normal priority; the (fixed) lifetime latch was the only
      # real blocker.
      write_workflow_file!(Workflow.workflow_file_path(),
        max_concurrent_agents: 5,
        tracker_active_states: ["Todo", "In Progress", "Rework"]
      )

      rework = issue("rework-ticket", state: "rework")
      state = %State{max_concurrent_agents: 5}

      assert DispatchPolicy.queued_dispatch_demand?([rework], state)
      assert DispatchPolicy.dispatch_candidate?(rework, state)

      # A rework ticket is also directly dispatchable through should_dispatch_issue?
      # (dispatch candidate + free slot), the poll loop's per-issue gate.
      assert DispatchPolicy.should_dispatch_issue?(rework, state)
    end

    test "ignores running, claimed, paused, blocked, and unroutable issues" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 5)

      issues = [
        issue("running", []),
        issue("claimed", []),
        issue("paused", paused: true),
        issue("blocked", blocked_by: [%{state: "in-progress"}]),
        issue("remote", assigned_to_worker: false)
      ]

      state = %State{
        max_concurrent_agents: 5,
        running: %{"running" => %{issue: issue("running", []), control: %{status: :working}}},
        claimed: MapSet.new(["claimed"])
      }

      refute DispatchPolicy.queued_dispatch_demand?(issues, state)
    end

    test "ignores demand blocked by per-state capacity" do
      write_workflow_file!(Workflow.workflow_file_path(),
        max_concurrent_agents: 8,
        max_concurrent_agents_by_state: %{"todo" => 1}
      )

      running = %{
        "active" => %{issue: issue("active", state: "todo"), control: %{status: :working}}
      }

      state = %State{max_concurrent_agents: 8, running: running}

      refute DispatchPolicy.queued_dispatch_demand?([issue("queued", [])], state)
    end

    test "ignores demand blocked by worker-host capacity" do
      write_workflow_file!(Workflow.workflow_file_path(),
        max_concurrent_agents: 8,
        worker_ssh_hosts: ["worker-a"],
        worker_max_concurrent_agents_per_host: 1
      )

      running = %{
        "active" => %{
          issue: issue("active", state: "todo"),
          worker_host: "worker-a",
          control: %{status: :working}
        }
      }

      state = %State{max_concurrent_agents: 8, running: running}

      refute DispatchPolicy.queued_dispatch_demand?([issue("queued", [])], state)
    end
  end

  describe "CPU sample continuity" do
    test "cold start seeds the default cap after observing clear CPU headroom" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 10, target_load_average: 1.0)

      baseline = %{total: 1_000, idle: 800, runnable: 1}
      current = %{total: 1_200, idle: 960, runnable: 1}

      state = %State{
        max_concurrent_agents: 10,
        effective_concurrent_agents: 1,
        load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: nil}
      }

      seeded = DispatchPolicy.update_load_envelope(state, 0.0, 1.0, 16, 1_000, baseline, true)
      assert seeded.effective_concurrent_agents == 2
      assert seeded.load_envelope_state.last_decrease_ms == nil
      refute seeded.load_envelope_state.bootstrap_complete?

      ramped = DispatchPolicy.update_load_envelope(seeded, 0.0, 1.0, 16, 2_000, current, true)
      assert ramped.effective_concurrent_agents == 10
      assert ramped.load_envelope_state.last_decrease_ms == nil
      assert ramped.load_envelope_state.bootstrap_complete?
    end

    test "cold seed adds idle slots to used and reserved capacity" do
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

      assert seeded.effective_concurrent_agents == 14
      assert Slots.available_slots(seeded) == 12
      assert seeded.load_envelope_state.bootstrap_complete?
    end

    test "cold seed never shrinks a warmed envelope on consecutive samples" do
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

  describe "blocker and state helpers" do
    test "unknown blocker states block todo issues" do
      blocked = issue("blocked", state: "todo", blocked_by: [%{state: nil}])

      assert DispatchPolicy.todo_issue_blocked_by_non_terminal?(
               blocked,
               MapSet.new(["done", "cancelled"])
             )
    end

    test "normalizes issue state and slugs mixed case and whitespace" do
      assert DispatchPolicy.normalize_issue_state("  In Progress ") == "in progress"
      assert DispatchPolicy.normalize_issue_state(nil) == ""
      assert DispatchPolicy.state_slug("  In_Progress ") == "in-progress"
      assert DispatchPolicy.state_slug(nil) == nil
    end

    test "issue routing defaults true" do
      assert DispatchPolicy.issue_routable_to_worker?(%Issue{})
      refute DispatchPolicy.issue_routable_to_worker?(%Issue{assigned_to_worker: false})
    end
  end

  describe "state slot policy" do
    test "uses per-state caps with active running entries only" do
      write_workflow_file!(Workflow.workflow_file_path(),
        max_concurrent_agents: 5,
        max_concurrent_agents_by_state: %{"todo" => 1}
      )

      state = %State{
        max_concurrent_agents: 5,
        running: %{
          "active" => %{issue: issue("active", state: "todo"), control: %{status: :working}},
          "paused" => %{issue: issue("paused", state: "todo"), control: %{status: :paused}}
        }
      }

      refute DispatchPolicy.state_slots_available?(issue("next", state: "todo"), state)
      assert DispatchPolicy.state_slots_available?(issue("other", state: "rework"), state)
    end
  end

  defp issue(id, attrs) do
    struct!(
      Issue,
      Keyword.merge(
        [
          id: id,
          identifier: id && "repo##{id}",
          title: "title #{id}",
          state: "todo",
          priority: nil,
          created_at: nil,
          blocked_by: []
        ],
        attrs
      )
    )
  end
end
