defmodule Aiur.Workspace.ContextTest do
  use ExUnit.Case, async: true

  alias Aiur.Workspace.Context

  test "build prefixes PR anchored issue identifiers and preserves head ref" do
    context =
      Context.build(%{
        id: "issue-pr-77",
        identifier: "77",
        title: "Ignored title",
        pr_head_ref: "feature/login"
      })

    assert context.issue_id == "issue-pr-77"
    assert context.issue_identifier == "pr-77"
    assert context.pr_head_ref == "feature/login"
    assert context.branch_name == "feature/login"
  end

  test "build gives new tracker issues a readable branch" do
    assert %{issue_identifier: "77", pr_head_ref: nil, branch_name: "aiur/77-add-new-test-cases"} =
             Context.build(%{
               id: "issue-77",
               identifier: "77",
               title: "Add New Test Cases for Hooks",
               pr_head_ref: ""
             })

    assert %{issue_identifier: "78", pr_head_ref: nil, branch_name: "aiur/78"} =
             Context.build(%{id: "issue-78", identifier: "78"})
  end

  test "build converts binary identifiers to identifier contexts" do
    assert Context.build("ABC-1") == %{
             issue_id: nil,
             issue_identifier: "ABC-1",
             issue_state: nil,
             issue_labels: [],
             pr_head_ref: nil,
             branch_name: "aiur/ABC-1"
           }
  end

  test "build falls back to issue for other terms" do
    assert %{issue_identifier: "issue", issue_id: nil, issue_state: nil, issue_labels: []} =
             Context.build(:unknown)
  end

  test "todo_dispatch? accepts todo state case and whitespace insensitively" do
    assert Context.todo_dispatch?(%{issue_state: " ToDo ", issue_labels: []})
  end

  test "todo_dispatch? accepts agent todo labels" do
    assert Context.todo_dispatch?(%{issue_state: nil, issue_labels: [" agent:todo "]})
  end

  test "todo_dispatch? rejects non todo contexts" do
    refute Context.todo_dispatch?(%{issue_state: nil, issue_labels: []})
    refute Context.todo_dispatch?(%{issue_state: "in-progress", issue_labels: ["agent:rework"]})
  end

  test "log_context renders fallback issue id" do
    assert Context.log_context(%{issue_id: nil, issue_identifier: "ABC-1"}) ==
             "issue_id=n/a issue_identifier=ABC-1"
  end

  test "worker_host_for_log renders local fallback" do
    assert Context.worker_host_for_log(nil) == "local"
  end
end
