defmodule Aiur.Orchestrator.ReworkDependencyHoldTest do
  # #4898: a rework ticket whose PR is stacked on an open blocker's PR was
  # dispatched and looped on no-op rework turns.
  use Aiur.TestSupport

  alias Aiur.{Issue, Tracker, Workflow}
  alias Aiur.Orchestrator.{Dispatcher, State}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["todo", "in-progress", "rework"]
    )

    Application.put_env(:aiur, :memory_tracker_recipient, self())
    :ok
  end

  test "a rework ticket with an open blocker is held, not dispatched" do
    issue = %Issue{
      id: "3799",
      identifier: "3799",
      title: "stacked dependent",
      state: "rework",
      state_labels: ["rework"],
      selected_backend: "codex",
      labels: ["agent:rework"],
      blocked_by: [%{id: "3784", identifier: "3784", state: "rework"}]
    }

    Application.put_env(:aiur, :memory_tracker_issues, [issue])
    parent = self()

    state =
      Dispatcher.dispatch_issue(%State{max_concurrent_agents: 4, effective_concurrent_agents: 4}, issue, nil, nil,
        blocked_by_hydrator: &{:ok, &1},
        runner: fn _dispatched, _recipient, _opts -> send(parent, :runner_started) end
      )

    assert state.dispatch_declines[issue.id] == :dependency
    refute Map.has_key?(state.running, issue.id)
    refute MapSet.member?(state.claimed, issue.id)
    assert {:ok, [%Issue{state: "rework"}]} = Tracker.fetch_issue_states_by_ids([issue.id])
    refute_received :runner_started
    refute_received {:memory_tracker_state_update, _, _}
  end

  test "a rework ticket whose blockers are closed still dispatches" do
    issue = %Issue{
      id: "3800",
      identifier: "3800",
      title: "unblocked dependent",
      state: "rework",
      state_labels: ["rework"],
      selected_backend: "codex",
      labels: ["agent:rework"],
      blocked_by: [%{id: "3784", identifier: "3784", state: "Closed"}]
    }

    Application.put_env(:aiur, :memory_tracker_issues, [issue])

    state =
      Dispatcher.dispatch_issue(%State{max_concurrent_agents: 4, effective_concurrent_agents: 4}, issue, nil, nil,
        blocked_by_hydrator: &{:ok, &1},
        runner: fn _dispatched, _recipient, _opts -> :ok end
      )

    assert Map.has_key?(state.running, issue.id)
  end
end
