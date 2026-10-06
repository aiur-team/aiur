defmodule Aiur.Workspace.RemoveTest do
  use Aiur.TestSupport

  alias Aiur.Workflow
  alias Aiur.Workspace.{Remove, WipPreservation}

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

  test "a live lease skips removal before running before_remove", %{workspace: workspace, test_root: test_root} do
    marker = Path.join(test_root, "hook-ran")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: test_root, hook_before_remove: "touch #{marker}")
    init_checkout!(workspace)
    File.write!(Path.join(workspace, "work.txt"), "unfinished")
    Aiur.TestSupport.put_runtime_state_dir!(Path.join(test_root, "runtime-state"))
    guard = fn -> {:skipped, :live_lease} end

    assert {:skipped, :live_lease} = Remove.remove(workspace, nil, destroy_guard: guard)
    assert File.dir?(workspace)
    refute File.exists?(marker)
    assert {:ok, preservation_dir} = WipPreservation.workspace_dir(Path.basename(workspace))
    refute File.exists?(preservation_dir)
  end

  test "a lease claimed during the save prevents before_remove", %{workspace: workspace, test_root: test_root} do
    marker = Path.join(test_root, "hook-ran")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: test_root, hook_before_remove: "touch #{marker}")
    Process.put(:destroy_guard_calls, 0)

    guard = fn ->
      calls = Process.get(:destroy_guard_calls) + 1
      Process.put(:destroy_guard_calls, calls)
      if calls == 1, do: :ok, else: {:skipped, :live_lease}
    end

    assert {:skipped, :live_lease} = Remove.remove(workspace, nil, destroy_guard: guard)
    assert File.dir?(workspace)
    refute File.exists?(marker)
  end

  test "remote git status failure exits closed", %{test_root: test_root} do
    workspace = Path.join(test_root, "remote-workspace")
    fake_bin = Path.join(test_root, "bin")
    File.mkdir_p!(Path.join(workspace, ".git"))
    File.mkdir_p!(fake_bin)
    fake_git = Path.join(fake_bin, "git")
    File.write!(fake_git, "#!/bin/sh\nexit 1\n")
    File.chmod!(fake_git, 0o755)

    {_, status} =
      System.cmd("bash", ["-c", Remove.remote_dirty_check() <> "\nrm -rf \"$workspace\""],
        env: [{"workspace", workspace}, {"PATH", fake_bin <> ":" <> System.get_env("PATH")}],
        stderr_to_stdout: true
      )

    assert status == 76
    assert File.dir?(workspace)
  end

  test "remote unpushed commit check failure exits closed", %{test_root: test_root} do
    workspace = Path.join(test_root, "remote-workspace")
    fake_bin = Path.join(test_root, "bin")
    File.mkdir_p!(Path.join(workspace, ".git"))
    File.mkdir_p!(fake_bin)
    fake_git = Path.join(fake_bin, "git")
    File.write!(fake_git, "#!/bin/sh\ncase \"$*\" in *rev-list*) exit 1 ;; *) exit 0 ;; esac\n")
    File.chmod!(fake_git, 0o755)

    {_, status} =
      System.cmd("bash", ["-c", Remove.remote_dirty_check() <> "\nrm -rf \"$workspace\""],
        env: [{"workspace", workspace}, {"PATH", fake_bin <> ":" <> System.get_env("PATH")}],
        stderr_to_stdout: true
      )

    assert status == 76
    assert File.dir?(workspace)
  end

  test "remote dirty check preserves a clean checkout with a local-only commit", %{test_root: test_root} do
    workspace = Path.join(test_root, "remote-workspace")
    remote = Path.join(test_root, "origin.git")
    File.mkdir_p!(workspace)
    {_, 0} = System.cmd("git", ["init", "--quiet", "--bare", remote])
    {_, 0} = System.cmd("git", ["init", "--quiet", "-b", "main", workspace])
    {_, 0} = System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
    {_, 0} = System.cmd("git", ["-C", workspace, "config", "user.name", "Test"])
    File.write!(Path.join(workspace, "tracked.txt"), "baseline")
    {_, 0} = System.cmd("git", ["-C", workspace, "add", "tracked.txt"])
    {_, 0} = System.cmd("git", ["-C", workspace, "commit", "--quiet", "-m", "baseline"])
    {_, 0} = System.cmd("git", ["-C", workspace, "remote", "add", "origin", remote])
    {_, 0} = System.cmd("git", ["-C", workspace, "push", "--quiet", "-u", "origin", "main"])

    File.write!(Path.join(workspace, "local-only.txt"), "committed work")
    {_, 0} = System.cmd("git", ["-C", workspace, "add", "local-only.txt"])
    {_, 0} = System.cmd("git", ["-C", workspace, "commit", "--quiet", "-m", "local-only"])

    {output, status} =
      System.cmd("bash", ["-c", Remove.remote_dirty_check() <> "\nrm -rf \"$workspace\""],
        env: [{"workspace", workspace}],
        stderr_to_stdout: true
      )

    assert status == 75
    assert output =~ "commits not present on any remote"
    assert File.read!(Path.join(workspace, "local-only.txt")) == "committed work"
    assert {commit, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"])
    assert String.trim(commit) != ""
  end

  defp init_checkout!(workspace) do
    {_, 0} = System.cmd("git", ["init", "-q", workspace])
    File.write!(Path.join(workspace, "tracked.txt"), "baseline")
    {_, 0} = System.cmd("git", ["-C", workspace, "add", "tracked.txt"])
    {_, 0} = System.cmd("git", ["-C", workspace, "-c", "user.email=test@example.com", "-c", "user.name=Test", "commit", "-qm", "baseline"])
  end
end
