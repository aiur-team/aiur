defmodule Aiur.Workspace.LayoutTest do
  use Aiur.TestSupport

  alias Aiur.Workspace.Layout

  test "issue_workspace_path nests the github owner repo segment" do
    root = tmp_path("layout-github-root")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      workspace_root: root
    )

    assert Layout.issue_workspace_path(root, "123") == Path.join([root, "owner", "repo", "123"])
  end

  test "issue_workspace_path does not append an already present repo segment" do
    root = tmp_path("layout-github-root")
    namespaced_root = Path.join([root, "owner", "repo"])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      workspace_root: namespaced_root
    )

    assert Layout.issue_workspace_path(namespaced_root, "123") == Path.join(namespaced_root, "123")
  end

  test "issue_workspace_path is flat for memory tracker" do
    root = tmp_path("layout-memory-root")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root
    )

    assert Layout.issue_workspace_path(root, "123") == Path.join(root, "123")
  end

  test "safe_identifier maps disallowed characters and nil" do
    assert Layout.safe_identifier("a/b c:@") == "a_b_c__"
    assert Layout.safe_identifier(nil) == "issue"
  end

  test "local validate_workspace_path rejects root itself and paths outside root" do
    root = tmp_path("layout-validate-root")
    outside = tmp_path("layout-outside")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)

    assert {:error, {:workspace_equals_root, _, _}} = Layout.validate_workspace_path(root, nil)
    assert {:error, {:workspace_outside_root, _, _}} = Layout.validate_workspace_path(outside, nil)
  end

  test "remote validate_workspace_path rejects empty and invalid characters" do
    assert {:error, {:workspace_path_unreadable, "", :empty}} =
             Layout.validate_workspace_path("", "worker")

    assert {:error, {:workspace_path_unreadable, "bad\npath", :invalid_characters}} =
             Layout.validate_workspace_path("bad\npath", "worker")

    assert {:error, {:workspace_path_unreadable, "bad" <> <<0>> <> "path", :invalid_characters}} =
             Layout.validate_workspace_path("bad" <> <<0>> <> "path", "worker")
  end

  test "pr_anchored_workspace? only accepts pr prefixed leaves" do
    assert Layout.pr_anchored_workspace?("/tmp/workspaces/pr-77")
    refute Layout.pr_anchored_workspace?("/tmp/workspaces/77")
    refute Layout.pr_anchored_workspace?("/tmp/workspaces/not-pr-77")
  end

  defp tmp_path(name) do
    Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
  end
end
