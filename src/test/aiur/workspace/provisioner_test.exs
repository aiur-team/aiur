defmodule Aiur.Workspace.ProvisionerTest do
  use Aiur.TestSupport

  alias Aiur.Workflow
  alias Aiur.Workspace.Provisioner

  test "parse_remote_workspace_output/1 with valid marker line returns ok tuple" do
    noise = "some\npreamble\n"
    marker_line = "__AIUR_WORKSPACE__\t1\t/resolved/path\n"
    output = noise <> marker_line <> "more noise\n"

    assert {:ok, "/resolved/path", true} = Provisioner.parse_remote_workspace_output(output)
  end

  test "parse_remote_workspace_output/1 with created=0 returns created? false" do
    output = "noise\n__AIUR_WORKSPACE__\t0\t/some/path\nmore\n"

    assert {:ok, "/some/path", false} = Provisioner.parse_remote_workspace_output(output)
  end

  test "parse_remote_workspace_output/1 with malformed output returns error" do
    bad = "no marker here at all\nfoo\nbar\n"

    assert {:error, {:workspace_prepare_failed, :invalid_output, _}} =
             Provisioner.parse_remote_workspace_output(bad)
  end

  test "parse_remote_workspace_output/1 with wrong field count returns error" do
    # Only 2 fields instead of 3
    bad = "__AIUR_WORKSPACE__\t1\n"

    assert {:error, {:workspace_prepare_failed, :invalid_output, _}} =
             Provisioner.parse_remote_workspace_output(bad)
  end

  test "ensure_workspace/2 on an existing directory returns false and preserves contents" do
    tmp = Path.join(System.tmp_dir!(), "prov_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    sentinel = Path.join(tmp, "sentinel.txt")
    File.write!(sentinel, "wip")

    on_exit(fn -> File.rm_rf!(tmp) end)

    assert {:ok, ^tmp, false} = Provisioner.ensure_workspace(tmp, nil)
    assert File.read!(sentinel) == "wip"
  end

  test "ensure_workspace/2 on a stale plain file replaces it and returns created? true" do
    test_root = Path.join(System.tmp_dir!(), "prov_stale_#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)

    on_exit(fn -> File.rm_rf!(test_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    # Put a plain file where a workspace directory is expected
    workspace = Path.join(workspace_root, "stale-file-ws")
    File.write!(workspace, "stale data")

    assert {:ok, ^workspace, true} = Provisioner.ensure_workspace(workspace, nil)
    assert File.dir?(workspace)
  end
end
