defmodule Aiur.Orchestrator.DispatchPolicyTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.State

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
    test "cold start fast-ramps after the CPU baseline observes clear headroom" do
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 4, target_load_average: 1.0)

      baseline = %{total: 1_000, idle: 800, runnable: 1}
      current = %{total: 1_200, idle: 960, runnable: 1}

      state = %State{
        max_concurrent_agents: 4,
        effective_concurrent_agents: 1,
        load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: nil}
      }

      seeded = DispatchPolicy.update_load_envelope(state, 0.0, 1.0, 4, 1_000, baseline, true)
      assert seeded.effective_concurrent_agents == 2
      assert seeded.load_envelope_state.last_decrease_ms == nil

      ramped = DispatchPolicy.update_load_envelope(seeded, 0.0, 1.0, 4, 2_000, current, true)
      assert ramped.effective_concurrent_agents == 4
      assert ramped.load_envelope_state.last_decrease_ms == nil
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
