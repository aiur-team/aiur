defmodule Aiur.TrackerTest do
  use Aiur.TestSupport
  alias Aiur.{GitHub.OpenIssueSnapshot, Issue, Tracker, Tracker.IssueTracker, Workflow}

  test "GitHub facade reads the held snapshot" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    OpenIssueSnapshot.reset()
    on_exit(fn -> OpenIssueSnapshot.reset() end)
    assert :none = Tracker.open_issue_labels(60_000)
    labels = %{"7" => %{labels: ["agent:queued"], updated_at: nil}}
    OpenIssueSnapshot.put("owner", "repo", [7], labels)
    assert {:ok, ^labels, _} = Tracker.open_issue_labels(60_000)
  end

  test "unresolved GitHub repository has no label observation" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "invalid/repo/name")
    assert :none = Tracker.open_issue_labels(60_000)
  end

  test "memory facade returns configured labels and update times" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    previous = Application.get_env(:aiur, :memory_tracker_issues)

    on_exit(fn ->
      if previous == nil, do: Application.delete_env(:aiur, :memory_tracker_issues), else: Application.put_env(:aiur, :memory_tracker_issues, previous)
    end)

    updated_at = ~U[2026-10-06 00:00:00Z]
    Application.put_env(:aiur, :memory_tracker_issues, [%Issue{id: "7", labels: ["agent:queued"], updated_at: updated_at}, %Issue{id: "8", labels: [], updated_at: nil}, :invalid])
    before = System.system_time(:millisecond)
    assert {:ok, labels, taken_at} = Tracker.open_issue_labels(60_000)
    assert labels == %{"7" => %{labels: ["agent:queued"], updated_at: updated_at}, "8" => %{labels: [], updated_at: nil}}
    assert taken_at >= before and taken_at <= System.system_time(:millisecond)
  end

  test "Linear reports unsupported through the facade and adapter" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert {:error, :unsupported} = Tracker.open_issue_labels(60_000)
    assert {:error, :unsupported} = Aiur.Linear.Tracker.open_issue_labels(60_000)
    assert {:open_issue_labels, 1} in IssueTracker.behaviour_info(:optional_callbacks)
  end
end
