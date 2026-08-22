defmodule Aiur.Workspace.RemoveTest do
  use Aiur.TestSupport

  alias Aiur.Workflow
  alias Aiur.Workspace.Remove

  setup do
    test_root = Path.join(System.tmp_dir!(), "remove_test_#{System.pid()}-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "ws")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(test_root) end)
    {:ok, workspace: workspace, test_root: test_root}
  end

  test "remove/2 local removes an existing directory", %{workspace: workspace, test_root: test_root} do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: test_root)

    assert File.dir?(workspace)
    assert {:ok, _} = Remove.remove(workspace, nil)
    refute File.exists?(workspace)
  end

  test "remove_issue_workspaces/1 with non-binary identifier returns :ok", %{test_root: test_root} do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: test_root)

    assert :ok = Remove.remove_issue_workspaces(123)
  end

  test "remove/1 on a non-existent workspace returns {ok, []}", %{test_root: test_root} do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: test_root)

    missing = Path.join(test_root, "never-existed")
    assert {:ok, []} = Remove.remove(missing)
  end

  test "remove/2 with a failing before_remove hook still removes the workspace", %{workspace: workspace, test_root: test_root} do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      before_remove: "exit 1"
    )

    assert File.dir?(workspace)
    assert {:ok, _} = Remove.remove(workspace, nil)
    refute File.exists?(workspace)
  end
end
