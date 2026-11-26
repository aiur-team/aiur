defmodule Aiur.Workspace.TrackerBoundaryTest do
  use Aiur.TestSupport

  alias Aiur.{RepoBase, Tracker}
  alias Aiur.Workspace.Layout

  test "tracker workspace callbacks preserve GitHub, Linear and memory paths" do
    root = Aiur.TestSupport.tmp_root!("workspace-tracker-boundary")

    for {kind, segment, clone_url} <- [
          {"github", "owner/repo", "https://github.com/owner/repo.git"},
          {"linear", "workspace-project", nil},
          {"memory", nil, nil}
        ] do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: kind,
        tracker_repo: "owner/repo",
        tracker_project_slug: "workspace-project",
        workspace_root: root
      )

      assert Tracker.workspace_repo_segment() == segment
      assert Tracker.clone_url() == clone_url
      expected = if segment, do: Path.join([root, segment, "17"]), else: Path.join(root, "17")
      assert Layout.issue_workspace_path(root, "17") == expected
    end
  end

  test "prewarm retains its GitHub repository source for non-GitHub trackers" do
    key = {Aiur.GitHub.Config, :resolved_origin_repo}
    previous = :persistent_term.get(key, :unset)
    :persistent_term.put(key, "owner/repo")
    on_exit(fn -> if previous == :unset, do: :persistent_term.erase(key), else: :persistent_term.put(key, previous) end)

    for kind <- ["linear", "memory"] do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: kind, tracker_repo: "owner/repo")
      assert Tracker.clone_url() == nil
      path = Workflow.workflow_file_path()
      write_workflow_file_atomic!(path, File.read!(path) <> "prewarm:\n  enabled: true\n  base_build: echo build\n  poll_seconds: 0\n")
      assert :ok = Aiur.WorkflowStore.force_reload()
      state = %{phase: {:error, :existing}, build: nil, probe: nil, base_path: nil, dispatch_watchdog: nil}
      assert {:reply, {:error, :existing}, resolved} = RepoBase.handle_call(:refresh_for_dispatch, {self(), make_ref()}, state)
      assert resolved.base_path == RepoBase.base_path("https://github.com/owner/repo.git")
    end
  end

  test "Linear repo segment retains whitespace for the existing path sanitizer" do
    root = Aiur.TestSupport.tmp_root!("workspace-linear-boundary")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", tracker_project_slug: " project ")
    assert Tracker.workspace_repo_segment() == " project "
    assert Layout.issue_workspace_path(root, "17") == Path.join([root, "_project_", "17"])
  end
end
