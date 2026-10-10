Code.require_file("../../../support/dispatch_policy_fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.DispatchPolicy.StatesAndSlotsTest do
  use Aiur.TestSupport

  import Aiur.TestSupport.DispatchPolicyFixture

  alias Aiur.{Issue, Workflow}
  alias Aiur.Orchestrator.{DispatchPolicy, Slots, State}

  describe "no-agent-work states (#1759)" do
    # `merging` (PR sitting in GitHub's merge queue) and `ci-wait` (CI in flight)
    # are states where by definition no agent work exists. Dispatching into them
    # cannot produce progress, only cost, and each committed dispatch bills a
    # lifetime unit toward the terminal latch.
    test "a merging or ci-wait ticket is not dispatchable even when listed as an active state" do
      # The operator config that produced #1759 listed `merging` in
      # `active_states`, so the refusal must hold *despite* that listing —
      # otherwise this test would pass against the pre-fix code.
      write_workflow_file!(Workflow.workflow_file_path(),
        max_concurrent_agents: 5,
        tracker_active_states: ["todo", "in-progress", "rework", "merging", "ci-wait"]
      )

      state = %State{max_concurrent_agents: 5}
      active = DispatchPolicy.active_state_set()
      terminal = DispatchPolicy.terminal_state_set()

      # Control: the same ticket shape in a real work state IS dispatchable, so
      # a blanket-false predicate cannot satisfy this test.
      for workable <- ["todo", "in-progress", "rework"] do
        ticket = issue("work-#{workable}", state: workable)

        assert DispatchPolicy.candidate_issue?(ticket, active, terminal), "#{workable} must stay dispatchable"
        assert DispatchPolicy.dispatch_candidate?(ticket, state, active, terminal)
        assert DispatchPolicy.should_dispatch_issue?(ticket, state, active, terminal)
      end

      for parked <- ["merging", "ci-wait"] do
        ticket = issue("parked-#{parked}", state: parked)

        assert DispatchPolicy.no_agent_work_state?(parked)
        refute DispatchPolicy.candidate_issue?(ticket, active, terminal), "#{parked} must not be a candidate"
        refute DispatchPolicy.dispatch_candidate?(ticket, state, active, terminal)
        refute DispatchPolicy.should_dispatch_issue?(ticket, state, active, terminal)

        # The retry engine and the pre-spawn revalidation in
        # `Dispatcher.revalidate_issue_for_dispatch/3` both gate on this one, so
        # a ticket that flips into `merging` mid-flight is refused there too.
        refute DispatchPolicy.retry_candidate_issue?(ticket, terminal)

        # The poll cycle's queued-work signal must not count it as demand.
        refute DispatchPolicy.queued_dispatch_demand?([ticket], state)
      end
    end

    test "state matching is normalized and nil-safe" do
      assert DispatchPolicy.no_agent_work_state?("Merging")
      assert DispatchPolicy.no_agent_work_state?("  CI-Wait ")
      refute DispatchPolicy.no_agent_work_state?("human-review")
      refute DispatchPolicy.no_agent_work_state?(nil)
      refute DispatchPolicy.no_agent_work_state?(:merging)
    end
  end

  # #2075: a ticket carrying two `agent:*` state labels is a broken lifecycle
  # state — the fail-closed dispatch guard used to refuse it, silently dropping
  # the ticket from every poll with no error and no alert. The guard must
  # instead resolve the pair to a single deterministic state (`todo` wins: a
  # ticket that is also `todo` has no work for a `rework` verdict to mean
  # anything about) and continue the ordinary checks, so the ticket stays
  # dispatchable.
  describe "contradictory state labels (#2075)" do
    test "resolve_state_labels makes todo win over rework, in either label shape" do
      assert DispatchPolicy.resolve_state_labels(["todo", "rework"]) == "todo"
      assert DispatchPolicy.resolve_state_labels(["rework", "todo"]) == "todo"
      assert DispatchPolicy.resolve_state_labels(["agent:todo", "agent:rework"]) == "todo"
      assert DispatchPolicy.resolve_state_labels(["agent:rework", "agent:todo"]) == "todo"
      assert DispatchPolicy.resolve_state_labels(["Todo", "Rework"]) == "todo"
    end

    test "resolve_state_labels resolves other pairs by most-outstanding-work precedence" do
      # No `todo` present: the explicit precedence order decides the winner —
      # the label with the most outstanding work, not whichever sorts first
      # alphabetically (#2437). The terminal `done` never beats an outstanding
      # disposition: resolving a pair to a terminal state silently discards the
      # work (and the heal would close the ticket), where resolving to the
      # outstanding state only costs one agent look to re-mark it done.
      assert DispatchPolicy.resolve_state_labels(["rework", "in-progress"]) == "rework"
      assert DispatchPolicy.resolve_state_labels(["in-progress", "rework"]) == "rework"
      assert DispatchPolicy.resolve_state_labels(["done", "rework"]) == "rework"
      assert DispatchPolicy.resolve_state_labels(["rework", "done"]) == "rework"
      assert DispatchPolicy.resolve_state_labels(["error", "rework"]) == "rework"
      assert DispatchPolicy.resolve_state_labels(["cancelled", "rework"]) == "rework"
      assert DispatchPolicy.resolve_state_labels(["done", "in-progress"]) == "in-progress"
      assert DispatchPolicy.resolve_state_labels(["done", "human-review"]) == "human-review"
      assert DispatchPolicy.resolve_state_labels(["done", "error"]) == "error"
      # `ci-wait` is a transient sub-state and never wins a resolution (#2437):
      # a `ci-wait`+`rework` ticket is really a rework ticket whose stale
      # `ci-wait` was never cleared, so rework wins.
      assert DispatchPolicy.resolve_state_labels(["rework", "ci-wait"]) == "rework"
      assert DispatchPolicy.resolve_state_labels(["ci-wait", "human-review"]) == "human-review"
      assert DispatchPolicy.resolve_state_labels(["ci-wait"]) == "ci-wait"
      # Labels outside the precedence list (merging, cancelled, a future state)
      # lose to every known disposition but still outrank the transient
      # `ci-wait` — an unknown disposition must never lose to `ci-wait` either,
      # or the transient marker could win a resolution after all (#2437).
      assert DispatchPolicy.resolve_state_labels(["merging", "ci-wait"]) == "merging"
      assert DispatchPolicy.resolve_state_labels(["cancelled", "ci-wait"]) == "cancelled"
      assert DispatchPolicy.resolve_state_labels(["merging", "done"]) == "done"
    end

    test "resolve_state_labels handles empty, single, and non-list input" do
      assert DispatchPolicy.resolve_state_labels([]) == nil
      assert DispatchPolicy.resolve_state_labels(["todo"]) == "todo"
      assert DispatchPolicy.resolve_state_labels(["rework"]) == "rework"
      assert DispatchPolicy.resolve_state_labels(nil) == nil
      assert DispatchPolicy.resolve_state_labels("todo") == nil
    end

    test "a ticket carrying todo+rework resolves to todo and stays dispatchable" do
      write_workflow_file!(Workflow.workflow_file_path(),
        max_concurrent_agents: 5,
        tracker_active_states: ["todo", "in-progress", "rework"]
      )

      dual = issue("dual", state: "todo", state_labels: ["todo", "rework"])
      state = %State{max_concurrent_agents: 5}

      # The guard must not silently refuse the pair (the pre-fix behaviour):
      # it resolves to `todo` and dispatches like any other todo ticket.
      assert DispatchPolicy.dispatch_candidate?(dual, state)
      assert DispatchPolicy.queued_dispatch_demand?([dual], state)
      assert DispatchPolicy.should_dispatch_issue?(dual, state)
    end

    test "a ticket carrying rework + a second label still resolves and dispatches" do
      write_workflow_file!(Workflow.workflow_file_path(),
        max_concurrent_agents: 5,
        tracker_active_states: ["todo", "in-progress", "rework"]
      )

      dual = issue("dual-rework", state: "rework", state_labels: ["in-progress", "rework"])
      state = %State{max_concurrent_agents: 5}

      # No `todo` present, so the most-outstanding-work label wins (`rework`),
      # which is an active dispatchable state.
      assert DispatchPolicy.dispatch_candidate?(dual, state)
      assert DispatchPolicy.queued_dispatch_demand?([dual], state)
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

    test "a GitHub-closed blocker is terminal and does not block a todo issue" do
      terminal_states = MapSet.new(["done", "cancelled"])

      # `Aiur.GitHub.Issues.extract_state/2` resolves a closed GitHub issue to
      # "Closed", which is not an `agent:*` label and so is absent from the
      # configured terminal set. It must still count as terminal.
      for closed_state <- ["Closed", "closed", "  CLOSED  "] do
        blocked = issue("blocked", state: "todo", blocked_by: [%{state: closed_state}])

        assert DispatchPolicy.terminal_issue_state?(closed_state, terminal_states)

        refute DispatchPolicy.todo_issue_blocked_by_non_terminal?(blocked, terminal_states),
               "expected blocker state #{inspect(closed_state)} to be terminal"
      end
    end

    test "a closed blocker is terminal even when the terminal set is empty" do
      blocked = issue("blocked", state: "todo", blocked_by: [%{state: "Closed"}])

      refute DispatchPolicy.todo_issue_blocked_by_non_terminal?(blocked, MapSet.new())
    end

    test "configured terminal label states still clear the dependency gate" do
      terminal_states = MapSet.new(["done", "cancelled"])
      blocked = issue("blocked", state: "todo", blocked_by: [%{state: "Done"}, %{state: "cancelled"}])

      refute DispatchPolicy.todo_issue_blocked_by_non_terminal?(blocked, terminal_states)

      still_blocked = issue("blocked", state: "todo", blocked_by: [%{state: "Closed"}, %{state: "in-progress"}])

      assert DispatchPolicy.todo_issue_blocked_by_non_terminal?(still_blocked, terminal_states)
    end

    test "a nil blocker state is still non-terminal alongside a closed blocker" do
      terminal_states = MapSet.new(["done", "cancelled"])
      blocked = issue("blocked", state: "todo", blocked_by: [%{state: "Closed"}, %{state: nil}])

      refute DispatchPolicy.terminal_issue_state?(nil, terminal_states)
      assert DispatchPolicy.todo_issue_blocked_by_non_terminal?(blocked, terminal_states)
    end

    test "the hold description names only the blockers actually holding dispatch" do
      terminal_states = MapSet.new(["done", "cancelled"])

      blocked =
        issue("blocked",
          state: "todo",
          blocked_by: [
            blocker("36", "Closed"),
            blocker("37", "Closed"),
            blocker("41", "rework"),
            blocker("42", "Closed")
          ]
        )

      description = DispatchPolicy.describe_dependency_hold(blocked, terminal_states)

      assert description == "blocked by open dependency #41 (rework); 3 terminal dependencies ignored"
      refute description =~ "36"
      refute description =~ "42"
    end

    test "every open blocker is named when more than one holds dispatch" do
      terminal_states = MapSet.new(["done", "cancelled"])

      blocked =
        issue("blocked", state: "todo", blocked_by: [blocker("7", "todo"), blocker("8", "rework")])

      assert DispatchPolicy.describe_dependency_hold(blocked, terminal_states) ==
               "blocked by open dependencies #7 (todo), #8 (rework)"
    end

    test "an all-terminal blocked_by list is not a hold at all" do
      terminal_states = MapSet.new(["done", "cancelled"])

      blocked =
        issue("blocked", state: "todo", blocked_by: [blocker("7", "Closed"), blocker("8", "Done")])

      refute DispatchPolicy.todo_issue_blocked_by_non_terminal?(blocked, terminal_states)
      assert DispatchPolicy.non_terminal_blockers(blocked, terminal_states) == []
    end

    test "a blocker with no readable state is named as an unknown-state hold" do
      terminal_states = MapSet.new(["done", "cancelled"])

      blocked =
        issue("blocked", state: "todo", blocked_by: [blocker("9", nil), blocker("10", "Closed")])

      assert DispatchPolicy.describe_dependency_hold(blocked, terminal_states) ==
               "blocked by open dependency #9 (unknown state); 1 terminal dependency ignored"
    end

    test "a non-numeric blocker identifier is printed without a number sigil" do
      terminal_states = MapSet.new(["done", "cancelled"])
      blocked = issue("blocked", state: "todo", blocked_by: [blocker("KHALA-41", "rework")])

      assert DispatchPolicy.describe_dependency_hold(blocked, terminal_states) ==
               "blocked by open dependency KHALA-41 (rework)"
    end

    test "an unnameable blocked_by shape still reads as a hold" do
      terminal_states = MapSet.new(["done", "cancelled"])

      assert DispatchPolicy.describe_dependency_hold(
               issue("blocked", state: "todo", blocked_by: [%{state: nil}]),
               terminal_states
             ) =~ "blocked by open dependency %{state: nil}"

      assert DispatchPolicy.describe_dependency_hold(
               issue("blocked", state: "todo", blocked_by: :not_a_list),
               terminal_states
             ) == "blocked by a non-terminal dependency"
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

    test "dispatch decisions name a binding per-state cap while fleet slots remain free" do
      write_workflow_file!(Workflow.workflow_file_path(),
        max_concurrent_agents: 4,
        max_concurrent_agents_by_state: %{"todo" => 1}
      )

      state = %State{
        max_concurrent_agents: 4,
        effective_concurrent_agents: 4,
        running: %{
          "active" => %{issue: issue("active", state: "todo"), control: %{status: :working}}
        }
      }

      assert Slots.available_slots(state) == 3
      assert DispatchPolicy.dispatch_decision(issue("next", state: "todo"), state) == {:skip, :state_capacity}
    end

    test "dispatch decisions distinguish an orphaned claim from a live runner" do
      claimed = issue("claimed", [])

      assert DispatchPolicy.dispatch_decision(claimed, %State{claimed: MapSet.new([claimed.id])}) ==
               {:skip, :claimed_without_runtime}

      running = %{claimed.id => %{issue: claimed, control: %{status: :working}}}

      assert DispatchPolicy.dispatch_decision(claimed, %State{claimed: MapSet.new([claimed.id]), running: running}) ==
               {:skip, :already_running}
    end

    test "dispatch decisions defer a released claim until its scheduled auto-resume" do
      released = issue("rate-limited", [])

      state = %State{
        auto_resume: %{
          released.id => %{attempt: 1, cause: :rate_limit, due_at_ms: System.monotonic_time(:millisecond) + 60_000}
        }
      }

      assert DispatchPolicy.dispatch_decision(released, state) == {:skip, :auto_resume_pending}
    end

    test "manual resume shares canonical state and runtime refusals" do
      merging = issue("merging", state: "merging")
      released = issue("rate-limited", [])

      state = %State{
        auto_resume: %{
          released.id => %{attempt: 1, cause: :rate_limit, due_at_ms: System.monotonic_time(:millisecond) + 60_000}
        }
      }

      assert DispatchPolicy.manual_resume_decision(merging, state) == {:skip, :no_agent_work_state}
      assert DispatchPolicy.manual_resume_decision(released, state) == {:skip, :auto_resume_pending}
    end

    test "manual resume ignores paused reservations but respects the active fleet cap" do
      next = issue("next", [])
      paused = %{issue: issue("paused", []), control: %{status: :paused}}
      active = %{issue: issue("active", state: "rework"), control: %{status: :working}}

      assert DispatchPolicy.manual_resume_decision(next, %State{max_concurrent_agents: 1, running: %{"paused" => paused}}) ==
               :dispatch

      assert DispatchPolicy.manual_resume_decision(next, %State{max_concurrent_agents: 1, running: %{"active" => active}}) ==
               {:skip, :fleet_capacity}
    end

    test "dispatch decisions distinguish a workspace ownership wait from an orphaned claim" do
      claimed = issue("workspace-wait", [])

      state = %State{
        claimed: MapSet.new([claimed.id]),
        dispatch_recovery: %{
          workspace_ownership: %{
            waits: %{claimed.identifier => %{issue_id: claimed.id}},
            ready: %{}
          },
          codex_thrash_budget: %{}
        }
      }

      assert DispatchPolicy.dispatch_decision(claimed, state) ==
               {:skip, :workspace_ownership_waiting}
    end
  end
end
