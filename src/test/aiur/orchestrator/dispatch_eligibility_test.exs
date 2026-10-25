defmodule Aiur.Orchestrator.DispatchEligibilityTest do
  use Aiur.TestSupport
  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy}

  test "orchestrator sorts dispatch by priority then oldest created_at" do
    issue_same_priority_older = %Issue{
      id: "issue-old-high",
      identifier: "MT-200",
      title: "Old high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    issue_same_priority_newer = %Issue{
      id: "issue-new-high",
      identifier: "MT-201",
      title: "New high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-02 00:00:00Z]
    }

    issue_lower_priority_older = %Issue{
      id: "issue-old-low",
      identifier: "MT-199",
      title: "Old lower priority",
      state: "Todo",
      priority: 2,
      created_at: ~U[2025-12-01 00:00:00Z]
    }

    sorted =
      DispatchPolicy.sort_issues_for_dispatch([
        issue_lower_priority_older,
        issue_same_priority_newer,
        issue_same_priority_older
      ])

    assert Enum.map(sorted, & &1.identifier) == ["MT-200", "MT-201", "MT-199"]
  end

  test "todo issue with non-terminal blocker is not dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-1",
      identifier: "MT-1001",
      title: "Blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-1", identifier: "MT-1002", state: "In Progress"}]
    }

    refute DispatchPolicy.should_dispatch_issue?(issue, state)
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-1",
      identifier: "MT-1007",
      title: "Owned elsewhere",
      state: "Todo",
      assigned_to_worker: false
    }

    refute DispatchPolicy.should_dispatch_issue?(issue, state)
  end

  test "todo issue with terminal blockers remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-1",
      identifier: "MT-1003",
      title: "Ready work",
      state: "Todo",
      blocked_by: [%{id: "blocker-2", identifier: "MT-1004", state: "Closed"}]
    }

    assert DispatchPolicy.should_dispatch_issue?(issue, state)
  end

  test "polling does not auto-dispatch when a paused agent reserves the only slot" do
    paused_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: "MT-PAUSED",
      issue: %Issue{id: "issue-paused", identifier: "MT-PAUSED", state: "In Progress"},
      worker_host: nil,
      control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :paused},
      session_id: "thread-MT-PAUSED",
      started_at: DateTime.utc_now()
    }

    state = %Orchestrator.State{
      max_concurrent_agents: 1,
      running: %{"issue-paused" => paused_entry},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    queued = %Issue{id: "queued-1", identifier: "MT-Q1", title: "Q1", state: "Todo"}

    refute DispatchPolicy.should_dispatch_issue?(queued, state)
  end

  test "per-state slot cap honors the session-aware max, not just the workflow value" do
    # Regression: bumping the global max via ←/→ updated session_max in
    # the orchestrator state, but `state_slots_available?` was calling
    # `Config.max_concurrent_agents_for_state/1`, which falls back to the
    # *static* workflow value. With workflow max=2 and session bump to 5,
    # the in-flight-state count of 2 was tripping the per-state cap of 2
    # and dispatch was rejected — the UI flashed the cap red on every
    # attempt despite the bump.
    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 2)

    in_progress_entry = fn id ->
      %{
        pid: self(),
        ref: make_ref(),
        identifier: "MT-#{id}",
        issue: %Issue{id: "issue-#{id}", identifier: "MT-#{id}", state: "In Progress"},
        worker_host: nil,
        control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :working},
        session_id: "thread-MT-#{id}",
        started_at: DateTime.utc_now()
      }
    end

    state = %Orchestrator.State{
      max_concurrent_agents: 2,
      session_max_concurrent_agents: 5,
      running: %{
        "issue-a" => in_progress_entry.("A"),
        "issue-b" => in_progress_entry.("B")
      },
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    todo = %Issue{id: "queued-1", identifier: "MT-Q1", title: "Q1", state: "Todo"}

    assert DispatchPolicy.dispatch_candidate?(todo, state),
           "manual start of a queued ticket must be eligible after a session-max bump"

    assert DispatchPolicy.should_dispatch_issue?(todo, state),
           "polling must also see the bumped cap as the effective per-state limit"
  end

  test "manual start is eligible when paused holds the slot but active count is below max" do
    # The operator pressing space on a queued ticket bypasses the
    # paused-reserves-slot rule: paused agents do not count against the
    # active cap, so a free slot stays manually claimable. The polling
    # path stays blocked by the prior test.
    paused_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: "MT-PAUSED",
      issue: %Issue{id: "issue-paused", identifier: "MT-PAUSED", state: "In Progress"},
      worker_host: nil,
      control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :paused},
      session_id: "thread-MT-PAUSED",
      started_at: DateTime.utc_now()
    }

    state = %Orchestrator.State{
      max_concurrent_agents: 1,
      running: %{"issue-paused" => paused_entry},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    queued = %Issue{id: "queued-1", identifier: "MT-Q1", title: "Q1", state: "Todo"}

    assert DispatchPolicy.dispatch_candidate?(queued, state)
  end

  test "dispatch revalidation skips stale todo issue once a non-terminal blocker appears" do
    stale_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: []
    }

    refreshed_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
    }

    fetcher = fn ["blocked-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Dispatcher.revalidate_issue_for_dispatch(
               stale_issue,
               fetcher,
               DispatchPolicy.terminal_state_set()
             )

    assert skipped_issue.identifier == "MT-1005"

    assert skipped_issue.blocked_by == [
             %{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}
           ]
  end
end
