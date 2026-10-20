defmodule Aiur.GitHub.IssueExecutorOwnerTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.Issues

  setup do
    :ok =
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "sym"
      )

    :ok
  end

  test "normalization extracts the owner marker without treating it as workflow state" do
    issue = %{
      "number" => 811,
      "title" => "Held",
      "state" => "open",
      "labels" => [%{"name" => "sym:todo"}, %{"name" => "sym:executor:codex"}]
    }

    normalized = Issues.normalize_issue(issue, "owner", "repo", "sym")

    assert normalized.executor_owner == "codex"
    assert normalized.state == "todo"
    assert normalized.state_labels == ["todo"]
  end

  test "bare executor marker holds with an explicit unknown owner" do
    issue = %{
      "number" => 812,
      "title" => "Held",
      "state" => "open",
      "labels" => [%{"name" => "sym:executor"}]
    }

    normalized = Issues.normalize_issue(issue, "owner", "repo", "sym")

    assert normalized.executor_owner == "unknown"
    assert normalized.state == nil
  end
end
