defmodule Aiur.Workspace.DeletedEmptyFilesTest do
  use Aiur.TestSupport

  alias Aiur.Workflow
  alias Aiur.Workspace.{DeletedEmptyFiles, Refresh}

  setup do
    test_root = Aiur.TestSupport.tmp_root!("deleted_empty_files_test")
    origin = Path.join(test_root, "origin")
    workspace = Path.join(test_root, "ws")

    git!(["init", "--quiet", "-b", "main", origin])
    git!(["-C", origin, "config", "user.email", "t@example.com"])
    git!(["-C", origin, "config", "user.name", "T"])
    File.write!(Path.join(origin, "gone.ex"), "defmodule Gone, do: nil\n")
    File.write!(Path.join(origin, "README.md"), "v1\n")
    git!(["-C", origin, "add", "."])
    git!(["-C", origin, "commit", "--quiet", "-m", "initial"])
    git!(["-C", origin, "rm", "--quiet", "gone.ex"])
    git!(["-C", origin, "commit", "--quiet", "-m", "delete gone"])
    git!(["clone", "--quiet", origin, workspace])

    on_exit(fn -> Aiur.TestCleanup.rm_rf!(test_root) end)
    {:ok, workspace: workspace, test_root: test_root}
  end

  test "before_run refresh removes an empty file main deleted and keeps other untracked files (#7920)", %{
    workspace: workspace,
    test_root: test_root
  } do
    File.write!(Path.join(workspace, "gone.ex"), "")
    File.write!(Path.join(workspace, "new_empty.ex"), "")
    File.write!(Path.join(workspace, "work.ex"), "defmodule Work, do: nil\n")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: test_root)

    issue = %{id: 1, identifier: "test", state: "todo", labels: [], pr_head_ref: nil}
    assert :ok = Refresh.run(workspace, issue, nil)

    refute File.exists?(Path.join(workspace, "gone.ex")), "empty file main deleted survived the workspace refresh"
    assert File.read!(Path.join(workspace, "new_empty.ex")) == ""
    assert File.read!(Path.join(workspace, "work.ex")) == "defmodule Work, do: nil\n"
  end

  test "keeps a non-empty file at a path main deleted", %{workspace: workspace} do
    File.write!(Path.join(workspace, "gone.ex"), "restored work\n")

    assert {:ok, []} = DeletedEmptyFiles.remove(workspace, "origin/main")
    assert File.read!(Path.join(workspace, "gone.ex")) == "restored work\n"
  end

  defp git!(args) do
    {out, 0} = System.cmd("git", args, stderr_to_stdout: true)
    out
  end
end
