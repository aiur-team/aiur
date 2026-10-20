defmodule Aiur.Orchestrator.StatusExecutorOwnedTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.{State, StatusReport}

  test "status exposes the Executor owner on an idle ticket without a worker row" do
    issue = %Issue{id: "owner-42", identifier: "repo#42", state: "todo", title: "Executor work", executor_owner: "codex"}
    state = %State{last_polled_issues: %{issue.id => issue}, candidate_snapshot_fresh?: true}

    assert [%{executor_owner: "codex", reason: {:executor_owned, "codex"}, work_state: :idle}] =
             StatusReport.agent_statuses(state)
  end
end
