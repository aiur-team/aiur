defmodule Aiur.Workspace.RemoveTest do
  use Aiur.TestSupport

  alias Aiur.Workflow
  alias Aiur.Workspace.Remove

  setup do
    test_root = Aiur.TestSupport.tmp_root!("remove_test")
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

  test "dirty checkout survives removal without running before_remove", %{workspace: workspace, test_root: test_root} do
    marker = Path.join(test_root, "hook-ran")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: test_root, hook_before_remove: "touch #{marker}")
    init_checkout!(workspace)
    File.write!(Path.join(workspace, "work.txt"), "unfinished")

    assert {:error, {:workspace_not_safe_to_delete, ^workspace, :dirty}, ""} = Remove.remove(workspace, nil)
    assert File.read!(Path.join(workspace, "work.txt")) == "unfinished"
    refute File.exists?(marker)
  end

  test "work created by before_remove survives the final deletion check", %{workspace: workspace, test_root: test_root} do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: test_root, hook_before_remove: "touch new-work.txt")
    init_checkout!(workspace)

    assert {:error, {:workspace_not_safe_to_delete, ^workspace, :dirty}, ""} = Remove.remove(workspace, nil)
    assert File.exists?(Path.join(workspace, "new-work.txt"))
  end

  defp init_checkout!(workspace) do
    {_, 0} = System.cmd("git", ["init", "-q", workspace])
    File.write!(Path.join(workspace, "tracked.txt"), "baseline")
    {_, 0} = System.cmd("git", ["-C", workspace, "add", "tracked.txt"])
    {_, 0} = System.cmd("git", ["-C", workspace, "-c", "user.email=test@example.com", "-c", "user.name=Test", "commit", "-qm", "baseline"])
  end
end
