defmodule Aiur.Workspace.RuntimeScratchSetAsideTest do
  use Aiur.TestSupport

  alias Aiur.Workflow
  alias Aiur.Workspace.Provisioner

  setup do
    test_root = Aiur.TestSupport.tmp_root!("prov_runtime_scratch")
    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(test_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    %{workspace_root: workspace_root, workspace: Path.join(workspace_root, "4962")}
  end

  test "moves a runtime-scratch-only workspace aside and bootstraps a fresh one", ctx do
    %{workspace: workspace, workspace_root: workspace_root} = ctx
    scratch = Path.join([workspace, ".aiur-runtime", "tmp", "aiur-test-logs-1", "run.log"])
    File.mkdir_p!(Path.dirname(scratch))
    File.write!(scratch, "scratch\n")

    assert {:ok, ^workspace, true} = Provisioner.ensure_workspace(workspace, nil, nil, "aiur/4962-runtime", nil, nil)
    refute File.exists?(Path.join(workspace, ".aiur-runtime/tmp"))

    assert [stale] = Path.wildcard(Path.join(workspace_root, "4962.stale-*"))
    assert File.read!(Path.join([stale, ".aiur-runtime", "tmp", "aiur-test-logs-1", "run.log"])) == "scratch\n"
  end

  # Regression guard: passes on main too; locks in that set-aside never widens past runtime scratch.
  test "keeps a workspace with other unknown content ambiguous and in place", ctx do
    %{workspace: workspace, workspace_root: workspace_root} = ctx
    File.mkdir_p!(Path.join(workspace, ".aiur-runtime/tmp"))
    notes = Path.join(workspace, "notes.txt")
    File.write!(notes, "agent WIP\n")

    assert {:error, {:workspace_ambiguous, ^workspace, :unproven_contents}} =
             Provisioner.ensure_workspace(workspace, nil, nil, "aiur/4962-runtime", nil)

    assert File.read!(notes) == "agent WIP\n"
    assert Path.wildcard(Path.join(workspace_root, "4962.stale-*")) == []
  end
end
