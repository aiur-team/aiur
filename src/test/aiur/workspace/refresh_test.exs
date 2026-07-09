defmodule Aiur.Workspace.RefreshTest do
  use Aiur.TestSupport

  alias Aiur.Workflow
  alias Aiur.Workspace.Refresh

  setup do
    test_root = Path.join(System.tmp_dir!(), "refresh_test_#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "ws")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(test_root) end)
    {:ok, workspace: workspace, test_root: test_root}
  end

  test "maybe_recreate_stale_workspace/6 with non-stale error passes error through", %{workspace: workspace} do
    error = {:error, {:workspace_hook_failed, "before_run", 1, ""}}
    reason = {:workspace_hook_failed, "before_run", 1, ""}
    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}

    assert ^error =
             Refresh.maybe_recreate_stale_workspace(error, reason, "some_cmd", workspace, issue_context, nil)
  end

  test "run/3 with no before_run configured returns :ok", %{workspace: workspace, test_root: test_root} do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: test_root)

    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}
    assert :ok = Refresh.run(workspace, issue_context, nil)
  end

  test "run/3 exit-65 on todo dispatch recreates workspace and re-runs before_run", %{workspace: workspace, test_root: test_root} do
    sentinel = Path.join(workspace, "leftover-sentinel")
    File.write!(sentinel, "leftover")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      hook_before_run: "exit 65"
    )

    # Use the raw issue map form so Context.build picks up state: "todo" as todo_dispatch?
    issue = %{id: 1, identifier: "test", state: "todo", labels: [], pr_head_ref: nil}

    # Recreation happens: sentinel gone, before_run fails again → error propagates
    assert {:error, _} = Refresh.run(workspace, issue, nil)
    refute File.exists?(sentinel)
  end

  test "run/3 exit-65 on non-todo dispatch returns :ok (WIP skip)", %{workspace: workspace, test_root: test_root} do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      before_run: "exit 65"
    )

    issue_context = %{
      issue_id: 1,
      issue_identifier: "test",
      issue_state: "in_progress",
      issue_labels: [],
      pr_head_ref: nil
    }

    assert :ok = Refresh.run(workspace, issue_context, nil)
  end
end
