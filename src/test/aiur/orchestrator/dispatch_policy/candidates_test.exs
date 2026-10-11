Code.require_file("../../../support/dispatch_policy_fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.DispatchPolicy.CandidatesTest do
  use Aiur.TestSupport

  import Aiur.TestSupport.DispatchPolicyFixture

  alias Aiur.BuildQueue.Hints
  alias Aiur.{Issue, Workflow}
  alias Aiur.Orchestrator.{DispatchPolicy, State}

  describe "sort_issues_for_dispatch/1" do
    # Compatibility guard: deliberately passes against the pre-hints implementation.
    test "sort is unchanged with no hints table or an empty table" do
      assert :ets.whereis(Hints.table_name()) == :undefined

      issues =
        for n <- 20..1//-1 do
          issue(to_string(n),
            priority: Enum.at([nil, 1, 2, 3, 4, 9], rem(n, 6)),
            created_at: if(rem(n, 4) == 0, do: nil, else: DateTime.add(~U[2026-01-01 00:00:00Z], rem(n, 3)))
          )
        end

      issues = [nil | issues]

      expected =
        Enum.sort_by(issues, fn
          %Issue{} = issue ->
            priority = if issue.priority in 1..4, do: issue.priority, else: 5
            age = if issue.created_at, do: DateTime.to_unix(issue.created_at, :microsecond), else: 9_223_372_036_854_775_807
            {priority, age, issue.identifier || issue.id || ""}

          _ ->
            {5, 9_223_372_036_854_775_807, ""}
        end)

      assert DispatchPolicy.sort_issues_for_dispatch(issues) == expected
      :ets.new(Hints.table_name(), [:named_table, :set])
      assert DispatchPolicy.sort_issues_for_dispatch(issues) == expected
    end

    test "a queue item with downstream 3 precedes a priority:1 non-queue item" do
      :ets.new(Hints.table_name(), [:named_table, :set])
      :ets.insert(Hints.table_name(), {"7", {-3, 0}, false})
      issues = [issue("1", priority: 1), issue("7", priority: 4)]

      assert Enum.map(DispatchPolicy.sort_issues_for_dispatch(issues), & &1.id) == ["7", "1"]
    end

    test "list position orders equal-priority queue items before age but after priority" do
      :ets.new(Hints.table_name(), [:named_table, :set])
      :ets.insert(Hints.table_name(), [{"1", {-3, 1}, false}, {"2", {-3, 2}, false}, {"3", {-3, 9}, false}])

      issues = [
        issue("2", priority: 2, created_at: ~U[2026-01-01 00:00:00Z]),
        issue("1", priority: 2, created_at: ~U[2026-01-02 00:00:00Z]),
        issue("3", priority: 1, created_at: ~U[2026-01-03 00:00:00Z])
      ]

      assert Enum.map(DispatchPolicy.sort_issues_for_dispatch(issues), & &1.id) == ["3", "1", "2"]
    end

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

    test "an in-progress ticket without a running agent is recovered as dispatchable work" do
      write_workflow_file!(Workflow.workflow_file_path(),
        max_concurrent_agents: 5,
        tracker_active_states: ["todo", "in-progress", "rework"]
      )

      stranded = issue("stranded-in-progress", state: "in-progress")
      state = %State{max_concurrent_agents: 5, running: %{}}

      assert DispatchPolicy.queued_dispatch_demand?([stranded], state)
      assert DispatchPolicy.dispatch_candidate?(stranded, state)
      assert DispatchPolicy.should_dispatch_issue?(stranded, state)
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

    test "ignores a parked issue even when it carries an active state label" do
      # #1971: `agent:parked` is the explicit operator-held marker. Unlike the
      # paused override (which preserves a running session), parking means "do
      # not dispatch this at all" — so a `todo` ticket with `agent:parked` must
      # not surface as queued demand, be a dispatch candidate, or pass the
      # should_dispatch_issue? gate.
      write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 5)

      parked = issue("parked-ticket", state: "todo", parked: true, labels: ["agent:todo", "agent:parked"])
      state = %State{max_concurrent_agents: 5}

      refute DispatchPolicy.queued_dispatch_demand?([parked], state)
      refute DispatchPolicy.dispatch_candidate?(parked, state)
      refute DispatchPolicy.should_dispatch_issue?(parked, state)
      assert DispatchPolicy.dispatch_decision(parked, state) == {:skip, :parked}
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
end
