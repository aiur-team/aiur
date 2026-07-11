defmodule Aiur.Orchestrator.WorkspaceCleanupTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.WorkspaceCleanup

  test "exposes terminal artifact cleanup" do
    assert function_exported?(WorkspaceCleanup, :cleanup_terminal_issue_artifacts, 2)
  end
end
