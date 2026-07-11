defmodule Aiur.Orchestrator.IssueSyncTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.{IssueSync, State}

  test "ignores a non-list poll result" do
    state = %State{last_polled_issues: %{"42" => %{id: "42"}}}

    assert IssueSync.sync_polled_issue_state(state, :invalid) == state
  end
end
