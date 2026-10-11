defmodule Aiur.WorkspaceDirtyRefreshTest do
  use Aiur.TestSupport
  alias Aiur.Workspace.WipPreservation

  test "before_run preserves and recreates dirty leftover workspaces for todo dispatches" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-before-run-stale-leftover")

    try do
      {workspace, trace_file} = bootstrap_dirty_refresh_workspace!(test_root, "STALE-1")

      issue = %Issue{
        id: "issue-stale-1",
        identifier: "STALE-1",
        title: "Recover stale workspace",
        state: "todo",
        labels: ["agent:todo"]
      }

      assert_stale_refresh_saved!(workspace, issue.identifier, trace_file, issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "before_run preserves dirty leftover workspaces when retry still carries todo label" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-before-run-stale-leftover-retry")

    try do
      {workspace, trace_file} = bootstrap_dirty_refresh_workspace!(test_root, "STALE-RETRY-1")

      issue = %Issue{
        id: "issue-stale-retry-1",
        identifier: "STALE-RETRY-1",
        title: "Recover stale retry workspace",
        state: "in-progress",
        labels: ["agent:todo"]
      }

      assert_stale_refresh_saved!(workspace, issue.identifier, trace_file, issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "before_run stale recreation uses exit 65 rather than output wording" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-before-run-stale-leftover-exit-code")

    try do
      {workspace, trace_file} =
        bootstrap_dirty_refresh_workspace!(test_root, "STALE-65-ONLY", refusal_output: "changed operator-facing refusal text")

      issue = %Issue{
        id: "issue-stale-65-only",
        identifier: "STALE-65-ONLY",
        title: "Recover stale workspace by exit code",
        state: "todo",
        labels: ["agent:todo"]
      }

      assert_stale_refresh_saved!(workspace, issue.identifier, trace_file, issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "checked-in before_run hook exposes exit 65 as the refresh refusal contract" do
    hooks_path = Path.expand("../../../../.aiur/hooks", __DIR__)
    hooks = File.read!(hooks_path)

    assert hooks =~ "exit 65"
    refute hooks =~ "matched by Workspace.stale_leftover_refresh_refusal?"
  end

  # Regression for #653. A base-branch push (a PR merge) — or a
  # resume-after-idle — fires before_run on a still-working agent. The agent
  # is mid-implementation with uncommitted tracked WIP, so before_run hits the
  # #569 dirty guard and exits 65. Before this fix that exit propagated as an
  # error, the agent run "failed", retried 3x, and gave up (retry_exhausted).
  # That meant every PR merge in the dogfood loop killed every OTHER in-flight
  # agent that had not yet committed. WHY this must hold: an in-flight agent's
  # uncommitted work is its legitimate WIP — base movement must NOT kill it.
  # The fix skips the origin/main refresh non-fatally and leaves the WIP intact
  # so the agent keeps working on its branch (it rebases/merges at PR time).
  test "before_run skips refresh and preserves WIP for dirty in-progress resume (does not retry-exhaust the agent)" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-before-run-protect-resume")

    try do
      {workspace, trace_file} = bootstrap_dirty_refresh_workspace!(test_root, "LIVE-1")

      issue = %Issue{
        id: "issue-live-1",
        identifier: "LIVE-1",
        title: "Protect resume workspace",
        state: "in-progress",
        labels: ["agent:in-progress"]
      }

      # :ok (not {:error, ...}) is what keeps the agent alive: run_on_worker_host
      # only proceeds to the turn loop when run_before_run_hook returns :ok, and
      # an error here is what booked the retry-exhausting failure.
      assert :ok = Workspace.run_before_run_hook(workspace, issue)

      # The agent's uncommitted WIP survives untouched — it was NOT recreated
      # clean and the origin/main merge was skipped, not applied.
      assert File.read!(Path.join(workspace, "README.md")) == "dirty\n"

      # before_run ran exactly once: a live resume skips, it does not recreate
      # the workspace (which would re-run before_run, recording a second trace
      # line — that recreate path is reserved for fresh todo dispatches, #577).
      assert trace_file |> File.read!() |> String.split("\n", trim: true) |> length() == 1
    after
      File.rm_rf(test_root)
    end
  end

  test "materialize_from_base creates the workspace's parent dir when missing (repo-namespaced layout)" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-materialize-parent")

    try do
      base = Path.join(test_root, "base")
      File.mkdir_p!(base)
      File.write!(Path.join(base, "README.md"), "warm base\n")
      System.cmd("git", ["-C", base, "init", "-b", "main"])
      System.cmd("git", ["-C", base, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", base, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", base, "add", "README.md"])
      System.cmd("git", ["-C", base, "commit", "-m", "initial"])

      # Repo-namespaced layout `<root>/<repo>/<issue>` where the `<repo>` parent
      # dir does not exist yet (first agent for a repo). Regression: the
      # materialize path was missing the parent mkdir the cold path has, so `cp`
      # failed with "No such file or directory" and fell back to a cold clone.
      workspace = Path.join([test_root, "workspaces", "some-repo", "429"])
      refute File.exists?(Path.dirname(workspace))

      assert :ok = Workspace.materialize_from_base(base, workspace)
      assert File.dir?(workspace)
      assert File.read!(Path.join(workspace, "README.md")) == "warm base\n"

      assert {branch, 0} = System.cmd("git", ["-C", workspace, "branch", "--show-current"])
      assert String.trim(branch) == "aiur/429"
    after
      File.rm_rf(test_root)
    end
  end

  test "after_create hook receives repository URL and configured base branch" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-hook-repo-url")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      out_file = Path.join(test_root, "repo-url.txt")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_kind: "github",
        tracker_repo: "test-org/test-repo",
        tracker_base_branch: "v2",
        hook_after_create: "printf '%s\\n%s' \"$THIS_REPOSITORY_URL\" \"$THIS_BASE_BRANCH\" > #{out_file}"
      )

      assert {:ok, _workspace} = Workspace.create_for_issue("S-URL")
      assert File.read!(out_file) == "https://github.com/test-org/test-repo.git\nv2"
    after
      File.rm_rf(test_root)
    end
  end

  test "materialize branches from the live configured base rather than main" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-workspace-configured-base")

    try do
      origin = Path.join(test_root, "origin.git")
      seed = Path.join(test_root, "seed")
      base = Path.join(test_root, "warm-base")
      workspace = Path.join(test_root, "workspaces/909")

      File.mkdir_p!(test_root)
      assert {_, 0} = System.cmd("git", ["init", "--bare", "-b", "main", origin])
      assert {_, 0} = System.cmd("git", ["clone", origin, seed])
      assert {_, 0} = System.cmd("git", ["-C", seed, "config", "user.email", "test@example.com"])
      assert {_, 0} = System.cmd("git", ["-C", seed, "config", "user.name", "Test User"])

      File.write!(Path.join(seed, "README.md"), "main base\n")
      assert {_, 0} = System.cmd("git", ["-C", seed, "add", "."])
      assert {_, 0} = System.cmd("git", ["-C", seed, "commit", "-m", "main base"])
      assert {_, 0} = System.cmd("git", ["-C", seed, "push", "origin", "main"])

      assert {_, 0} = System.cmd("git", ["-C", seed, "checkout", "-b", "v2"])
      File.write!(Path.join(seed, "README.md"), "v2 base\n")
      assert {_, 0} = System.cmd("git", ["-C", seed, "commit", "-am", "v2 base"])
      assert {_, 0} = System.cmd("git", ["-C", seed, "push", "origin", "v2"])
      assert {_, 0} = System.cmd("git", ["clone", "--branch", "v2", origin, base])

      assert {_, 0} = System.cmd("git", ["-C", seed, "checkout", "main"])
      File.write!(Path.join(seed, "README.md"), "main advanced\n")
      assert {_, 0} = System.cmd("git", ["-C", seed, "commit", "-am", "main advance"])
      assert {_, 0} = System.cmd("git", ["-C", seed, "push", "origin", "main"])
      main_tip = git_head!(seed)

      assert {_, 0} = System.cmd("git", ["-C", seed, "checkout", "v2"])
      File.write!(Path.join(seed, "README.md"), "v2 advanced\n")
      assert {_, 0} = System.cmd("git", ["-C", seed, "commit", "-am", "v2 advance"])
      assert {_, 0} = System.cmd("git", ["-C", seed, "push", "origin", "v2"])
      v2_tip = git_head!(seed)

      write_workflow_file!(Workflow.workflow_file_path(), tracker_base_branch: "v2")
      assert :ok = Workspace.materialize_from_base(base, workspace)

      assert git_head!(workspace) == v2_tip
      refute git_head!(workspace) == main_tip
      assert File.read!(Path.join(workspace, "README.md")) == "v2 advanced\n"
    after
      File.rm_rf!(test_root)
    end
  end

  defp assert_stale_refresh_saved!(workspace, identifier, trace_file, issue) do
    assert :ok = Workspace.run_before_run_hook(workspace, issue)
    assert File.read!(Path.join(workspace, "README.md")) == "initial\n"
    assert trace_file |> File.read!() |> String.split("\n", trim: true) |> length() == 2

    assert [notice] = WipPreservation.pending_notices(workspace, identifier)
    assert notice["action"] == "recreate the stale workspace"
    assert notice["tracked_files"] == ["README.md"]

    {prompt, [^notice]} = WipPreservation.with_pending_notices(workspace, identifier, "continue work")
    assert prompt =~ notice["artifact_dir"]
    assert prompt =~ "Restore with these commands"
    assert Enum.any?(notice["restore_commands"], &String.contains?(&1, "git apply --binary"))
  end

  defp bootstrap_dirty_refresh_workspace!(test_root, identifier, opts \\ []) do
    source_repo = Path.join(test_root, "source")
    remote_repo = Path.join(test_root, "remote.git")
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "before-run.trace")
    refusal_output = Keyword.get(opts, :refusal_output)

    File.mkdir_p!(source_repo)
    File.write!(Path.join(source_repo, "README.md"), "initial\n")
    git!(["-C", source_repo, "init", "-b", "main"])
    git!(["-C", source_repo, "config", "user.name", "Test User"])
    git!(["-C", source_repo, "config", "user.email", "test@example.com"])
    git!(["-C", source_repo, "add", "README.md"])
    git!(["-C", source_repo, "commit", "-m", "initial"])
    git!(["clone", "--bare", source_repo, remote_repo])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      hook_after_create: """
      PATH="/usr/bin:/bin:$PATH"
      git clone #{shell_quote(remote_repo)} .
      issue_id="$(basename "$PWD")"
      git checkout -b "aiur/${issue_id}" origin/main
      """,
      hook_before_run: """
      PATH="/usr/bin:/bin:$PATH"
      printf 'attempt\\n' >> #{shell_quote(trace_file)}
      if [ ! -d .git ] || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        find . -mindepth 1 -maxdepth 1 -exec rm -rf {} +
        git clone #{shell_quote(remote_repo)} .
        issue_id="$(basename "$PWD")"
        git checkout -b "aiur/${issue_id}" origin/main
      else
        git fetch origin main
        if ! git diff --quiet -- . || ! git diff --cached --quiet -- .; then
          echo #{shell_quote(refusal_output || "Refusing to refresh workspace from origin/main because tracked source changes are present.")} >&2
          echo #{shell_quote("Commit or resolve the workspace changes before resuming this agent.")} >&2
          exit 65
        fi
        git merge --no-edit origin/main
      fi
      """
    )

    assert {:ok, workspace} = Workspace.create_for_issue(identifier)
    File.write!(Path.join(workspace, "README.md"), "dirty\n")

    {workspace, trace_file}
  end

  defp git!(args) do
    {output, 0} = System.cmd("git", args, stderr_to_stdout: true)
    output
  end

  defp git_head!(repo) do
    {output, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"], stderr_to_stdout: true)
    String.trim(output)
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
