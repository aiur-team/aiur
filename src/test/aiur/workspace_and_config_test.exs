defmodule Aiur.WorkspaceAndConfigTest do
  use Aiur.TestSupport
  alias Aiur.CodingAgent
  alias Aiur.Config.Schema
  alias Aiur.Config.Schema.{Codex, StringOrMap}
  alias Aiur.Issue
  alias Aiur.Linear.Client
  alias Ecto.Changeset

  test "workspace bootstrap can be implemented in after_create hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-hook-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(Path.join(template_repo, "keep"))
      File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
      File.write!(Path.join(template_repo, "README.md"), "hook clone\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md", "keep/file.txt"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 #{template_repo} ."
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-1")
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "hook clone\n"
      assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace bootstrap supports normal git metadata writes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-git-metadata-#{System.unique_integer([:positive])}"
      )

    try do
      source_repo = Path.join(test_root, "source")
      remote_repo = Path.join(test_root, "remote.git")
      workspace_root = Path.join(test_root, "workspaces")
      cache_root = Path.join(test_root, "cache")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-git-metadata.trace")

      File.mkdir_p!(source_repo)
      File.write!(Path.join(source_repo, "README.md"), "initial\n")
      System.cmd("git", ["-C", source_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", source_repo, "add", "README.md"])
      System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"])
      System.cmd("git", ["clone", "--bare", source_repo, remote_repo])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [cache_root],
          networkAccess: true
        },
        hook_after_create: """
        git clone #{remote_repo} .
        issue_id="$(basename "$PWD")"
        git checkout -b "aiur/${issue_id}" origin/main
        git config user.name "Test User"
        git config user.email "test@example.com"
        """
      )

      assert {:ok, workspace} = Workspace.create_for_issue("GIT-1")
      assert {:ok, canonical_workspace} = Aiur.PathSafety.canonicalize(workspace)
      assert {:ok, runtime_settings} = Config.codex_runtime_settings(workspace)
      assert cache_root in runtime_settings.turn_sandbox_policy["writableRoots"]
      assert canonical_workspace in runtime_settings.turn_sandbox_policy["writableRoots"]

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"

      run_git_metadata_check() {
        workspace="$(pwd -P)"

        printf '%s' "$1" | grep -F '"sandboxPolicy"' >/dev/null || exit 20
        printf '%s' "$1" | grep -F '"writableRoots"' >/dev/null || exit 20
        printf '%s' "$1" | grep -F "$workspace" >/dev/null || exit 20

        git fetch origin >> "$trace_file" 2>&1 || exit 21
        test -f .git/FETCH_HEAD || exit 22
        git update-ref ORIG_HEAD HEAD >> "$trace_file" 2>&1 || exit 23
        test -f .git/ORIG_HEAD || exit 24

        printf 'workspace git metadata is writable\\n' > agent-change.txt
        git add agent-change.txt >> "$trace_file" 2>&1 || exit 25
        git commit -m "agent change" >> "$trace_file" 2>&1 || exit 26
        git push origin HEAD:refs/heads/aiur/GIT-1 >> "$trace_file" 2>&1 || exit 27
      }

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-git-metadata"}}}'
            ;;
          *'"method":"turn/start"'*)
            run_git_metadata_check "$line"
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-git-metadata"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      issue = %Issue{
        id: "issue-git-metadata",
        identifier: "GIT-1",
        title: "Validate git metadata writes",
        description: "Ensure Codex can write git metadata in the issue workspace",
        state: "In Progress",
        url: "https://example.org/issues/GIT-1",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Verify git metadata writes", issue)
      assert File.exists?(Path.join([workspace, ".git", "FETCH_HEAD"]))
      assert File.exists?(Path.join([workspace, ".git", "ORIG_HEAD"]))

      assert {_output, 0} =
               System.cmd("git", [
                 "--git-dir",
                 remote_repo,
                 "rev-parse",
                 "--verify",
                 "refs/heads/aiur/GIT-1"
               ])
    after
      File.rm_rf(test_root)
    end
  end

  test "before_run repairs stale git metadata locks before agent turns" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-before-run-git-locks-#{System.unique_integer([:positive])}"
      )

    try do
      source_repo = Path.join(test_root, "source")
      remote_repo = Path.join(test_root, "remote.git")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(source_repo)
      File.write!(Path.join(source_repo, "README.md"), "initial\n")
      System.cmd("git", ["-C", source_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", source_repo, "add", "README.md"])
      System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"])
      System.cmd("git", ["clone", "--bare", source_repo, remote_repo])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: """
        git clone #{remote_repo} .
        issue_id="$(basename "$PWD")"
        git checkout -b "aiur/${issue_id}" origin/main
        git config user.name "Test User"
        git config user.email "test@example.com"
        """
      )

      assert {:ok, workspace} = Workspace.create_for_issue("LOCK-1")

      stale_locks = [
        Path.join([workspace, ".git", "index.lock"]),
        Path.join([workspace, ".git", "FETCH_HEAD.lock"]),
        Path.join([workspace, ".git", "ORIG_HEAD.lock"]),
        Path.join([workspace, ".git", "refs", "remotes", "origin", "aiur", "LOCK-1.lock"])
      ]

      Enum.each(stale_locks, fn lock ->
        File.mkdir_p!(Path.dirname(lock))
        File.write!(lock, "stale\n")
      end)

      assert :ok = Workspace.run_before_run_hook(workspace, "LOCK-1")
      assert Enum.all?(stale_locks, &(not File.exists?(&1)))

      assert {_output, 0} = System.cmd("git", ["-C", workspace, "fetch", "origin"], stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["-C", workspace, "merge", "--no-edit", "origin/main"], stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", ["-C", workspace, "update-ref", "ORIG_HEAD", "HEAD"], stderr_to_stdout: true)

      File.write!(Path.join(workspace, "agent-change.txt"), "metadata writable\n")
      assert {_output, 0} = System.cmd("git", ["-C", workspace, "add", "agent-change.txt"])
      assert {_output, 0} = System.cmd("git", ["-C", workspace, "commit", "-m", "agent change"])

      assert {_output, 0} =
               System.cmd("git", ["-C", workspace, "push", "origin", "HEAD:refs/heads/aiur/LOCK-1"], stderr_to_stdout: true)

      assert {_output, 0} =
               System.cmd("git", [
                 "--git-dir",
                 remote_repo,
                 "rev-parse",
                 "--verify",
                 "refs/heads/aiur/LOCK-1"
               ])
    after
      File.rm_rf(test_root)
    end
  end

  test "before_run rejects git metadata outside the issue workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-external-gitdir-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "BAD-1")
      external_git_dir = Path.join(test_root, "external.git")

      File.mkdir_p!(workspace)

      assert {_output, 0} =
               System.cmd(
                 "git",
                 ["init", "--quiet", "-b", "main", "--separate-git-dir", external_git_dir, workspace],
                 stderr_to_stdout: true
               )

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root
      )

      assert {:error, reason} = Workspace.run_before_run_hook(workspace, "BAD-1")

      assert {:workspace_git_metadata_unwritable, ^workspace, {:git_dir_outside_workspace, rejected_git_dir}} =
               reason

      assert {:ok, canonical_external_git_dir} = Aiur.PathSafety.canonicalize(external_git_dir)
      assert rejected_git_dir == canonical_external_git_dir
    after
      File.rm_rf(test_root)
    end
  end

  test "before_run recreates dirty leftover workspaces for todo dispatches" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-before-run-stale-leftover-#{System.unique_integer([:positive])}"
      )

    try do
      {workspace, trace_file} = bootstrap_dirty_refresh_workspace!(test_root, "STALE-1")

      issue = %Issue{
        id: "issue-stale-1",
        identifier: "STALE-1",
        title: "Recover stale workspace",
        state: "todo",
        labels: ["agent:todo"]
      }

      assert :ok = Workspace.run_before_run_hook(workspace, issue)

      assert File.read!(Path.join(workspace, "README.md")) == "initial\n"
      assert String.trim(git!(["-C", workspace, "status", "--short"])) == ""
      assert trace_file |> File.read!() |> String.split("\n", trim: true) |> length() == 2
    after
      File.rm_rf(test_root)
    end
  end

  test "before_run recreates dirty leftover workspaces when retry still carries todo label" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-before-run-stale-leftover-retry-#{System.unique_integer([:positive])}"
      )

    try do
      {workspace, trace_file} = bootstrap_dirty_refresh_workspace!(test_root, "STALE-RETRY-1")

      issue = %Issue{
        id: "issue-stale-retry-1",
        identifier: "STALE-RETRY-1",
        title: "Recover stale retry workspace",
        state: "in-progress",
        labels: ["agent:todo"]
      }

      assert :ok = Workspace.run_before_run_hook(workspace, issue)

      assert File.read!(Path.join(workspace, "README.md")) == "initial\n"
      assert String.trim(git!(["-C", workspace, "status", "--short"])) == ""
      assert trace_file |> File.read!() |> String.split("\n", trim: true) |> length() == 2
    after
      File.rm_rf(test_root)
    end
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
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-before-run-protect-resume-#{System.unique_integer([:positive])}"
      )

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
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-materialize-parent-#{System.unique_integer([:positive])}"
      )

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

  test "after_create hook receives THIS_REPOSITORY_URL for the configured repo" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-hook-repo-url-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      out_file = Path.join(test_root, "repo-url.txt")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_kind: "github",
        tracker_repo: "test-org/test-repo",
        hook_after_create: "printf '%s' \"$THIS_REPOSITORY_URL\" > #{out_file}"
      )

      assert {:ok, _workspace} = Workspace.create_for_issue("S-URL")
      assert File.read!(out_file) == "https://github.com/test-org/test-repo.git"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace path is deterministic per issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-deterministic-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det")
    assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det")

    assert first_workspace == second_workspace
    assert Path.basename(first_workspace) == "MT_Det"
  end

  test "workspace path is namespaced by repo so issue numbers do not collide across repos" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-repo-namespace-#{System.unique_integer([:positive])}"
      )

    try do
      # GitHub: segment is the full owner/name, so issue #10 in two different
      # repos lands in two distinct directories.
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "octo/widgets",
        workspace_root: workspace_root
      )

      assert {:ok, widgets_ws} = Workspace.create_for_issue("10")

      assert {:ok, canonical_widgets} =
               Aiur.PathSafety.canonicalize(Path.join([workspace_root, "octo", "widgets", "10"]))

      assert widgets_ws == canonical_widgets
      # basename stays the bare issue id so `basename "$PWD"` still names the branch.
      assert Path.basename(widgets_ws) == "10"

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "octo/gadgets",
        workspace_root: workspace_root
      )

      assert {:ok, gadgets_ws} = Workspace.create_for_issue("10")
      assert gadgets_ws != widgets_ws
      assert Path.basename(Path.dirname(gadgets_ws)) == "gadgets"
      # owner is kept so forks of the same repo name never collide.
      assert gadgets_ws |> Path.dirname() |> Path.dirname() |> Path.basename() == "octo"

      # A bare repo name (no owner/ prefix) is used verbatim as the segment.
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "barerepo",
        workspace_root: workspace_root
      )

      assert {:ok, bare_ws} = Workspace.create_for_issue("10")
      assert Path.basename(Path.dirname(bare_ws)) == "barerepo"

      # Path-traversal components are dropped so the repo segment can't escape
      # the workspace root.
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "octo/../escape",
        workspace_root: workspace_root
      )

      assert {:ok, safe_ws} = Workspace.create_for_issue("10")
      refute safe_ws =~ ".."

      assert {:ok, canonical_safe} =
               Aiur.PathSafety.canonicalize(Path.join([workspace_root, "octo", "escape", "10"]))

      assert safe_ws == canonical_safe
    after
      File.rm_rf(workspace_root)
    end
  end

  test "repo namespacing is idempotent when the root already ends with the repo segment" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-idempotent-#{System.unique_integer([:positive])}"
      )

    try do
      # `aiur init` bakes owner/name into the root; materialization must not
      # double it into <root>/octo/widgets/octo/widgets/<issue>.
      baked_root = Path.join([workspace_root, "octo", "widgets"])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "octo/widgets",
        workspace_root: baked_root
      )

      assert {:ok, ws} = Workspace.create_for_issue("10")

      assert {:ok, expected} =
               Aiur.PathSafety.canonicalize(Path.join([workspace_root, "octo", "widgets", "10"]))

      assert ws == expected
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace falls back to a flat <root>/<issue> layout for the memory tracker" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-memory-flat-#{System.unique_integer([:positive])}"
      )

    try do
      # The memory tracker has no repo segment, so the issue dir sits directly
      # under the root (no namespacing).
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root
      )

      assert {:ok, canonical_flat} =
               Aiur.PathSafety.canonicalize(Path.join(workspace_root, "MEM-1"))

      assert {:ok, workspace} = Workspace.create_for_issue("MEM-1")
      assert workspace == canonical_flat
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace reuses existing issue directory without deleting local changes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo first > README.md"
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue("MT-REUSE")

      File.write!(Path.join(first_workspace, "README.md"), "changed\n")
      File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")
      File.mkdir_p!(Path.join(first_workspace, "deps"))
      File.mkdir_p!(Path.join(first_workspace, "_build"))
      File.mkdir_p!(Path.join(first_workspace, "tmp"))
      File.write!(Path.join([first_workspace, "deps", "cache.txt"]), "cached deps\n")
      File.write!(Path.join([first_workspace, "_build", "artifact.txt"]), "compiled artifact\n")
      File.write!(Path.join([first_workspace, "tmp", "scratch.txt"]), "remove me\n")

      assert {:ok, second_workspace} = Workspace.create_for_issue("MT-REUSE")
      assert second_workspace == first_workspace
      assert File.read!(Path.join(second_workspace, "README.md")) == "changed\n"
      assert File.read!(Path.join(second_workspace, "local-progress.txt")) == "in progress\n"
      assert File.read!(Path.join([second_workspace, "deps", "cache.txt"])) == "cached deps\n"

      assert File.read!(Path.join([second_workspace, "_build", "artifact.txt"])) ==
               "compiled artifact\n"

      assert File.read!(Path.join([second_workspace, "tmp", "scratch.txt"])) == "remove me\n"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace replaces stale non-directory paths" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-stale-path-#{System.unique_integer([:positive])}"
      )

    try do
      stale_workspace = Path.join([workspace_root, "project", "MT-STALE"])
      File.mkdir_p!(Path.dirname(stale_workspace))
      File.write!(stale_workspace, "old state\n")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace} = Aiur.PathSafety.canonicalize(stale_workspace)
      assert {:ok, workspace} = Workspace.create_for_issue("MT-STALE")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace rejects symlink escapes under the configured root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      symlink_path = Path.join([workspace_root, "project", "MT-SYM"])

      File.mkdir_p!(Path.dirname(symlink_path))
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_outside_root} = Aiur.PathSafety.canonicalize(outside_root)
      assert {:ok, canonical_workspace_root} = Aiur.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_outside_root, ^canonical_outside_root, ^canonical_workspace_root}} =
               Workspace.create_for_issue("MT-SYM")
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace canonicalizes symlinked workspace roots before creating issue directories" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-root-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      actual_root = Path.join(test_root, "actual-workspaces")
      linked_root = Path.join(test_root, "linked-workspaces")

      File.mkdir_p!(actual_root)
      File.ln_s!(actual_root, linked_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: linked_root)

      assert {:ok, canonical_workspace} =
               Aiur.PathSafety.canonicalize(Path.join([actual_root, "project", "MT-LINK"]))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-LINK")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-root-remove-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace_root} =
               Aiur.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_equals_root, ^canonical_workspace_root, ^canonical_workspace_root}, ""} =
               Workspace.remove(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook failures" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-hook-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo nope && exit 17"
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook timeouts" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-hook-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 10,
        hook_after_create: "sleep 1"
      )

      assert {:error, {:workspace_hook_timeout, "after_create", 10}} =
               Workspace.create_for_issue("MT-TIMEOUT")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace creates an empty directory when no bootstrap hook is configured" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-workspace-empty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      workspace = Path.join([workspace_root, "project", "MT-608"])
      assert {:ok, canonical_workspace} = Aiur.PathSafety.canonicalize(workspace)

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-608")
      assert File.dir?(workspace)
      assert {:ok, []} = File.ls(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace before_run seeds warm cache from configured bootstrap image" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-bootstrap-image-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("AIUR_TEST_DOCKER_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("AIUR_TEST_DOCKER_TRACE", previous_trace)
    end)

    try do
      fake_bin = Path.join(test_root, "bin")
      workspace_root = Path.join(test_root, "workspaces")
      trace_file = Path.join(test_root, "docker.trace")

      File.mkdir_p!(fake_bin)
      write_fake_docker!(Path.join(fake_bin, "docker"))

      System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))
      System.put_env("AIUR_TEST_DOCKER_TRACE", trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_bootstrap_image: "ghcr.io/its-everdred/aiur:latest",
        workspace_bootstrap_image_pull: true,
        hook_before_run: "echo before > before-run.log"
      )

      assert Config.settings!().workspace.bootstrap_image == "ghcr.io/its-everdred/aiur:latest"
      assert Config.workspace_bootstrap_image() == "ghcr.io/its-everdred/aiur:latest"
      assert Config.workspace_bootstrap_image_pull?()

      assert {:ok, workspace} = Workspace.create_for_issue("MT-IMAGE")
      assert :ok = Workspace.run_before_run_hook(workspace, "MT-IMAGE")

      assert File.read!(Path.join(workspace, "before-run.log")) == "before\n"
      assert File.read!(Path.join([workspace, "src", "deps", "from-image.txt"])) == "warm deps\n"
      assert File.read!(Path.join([workspace, "src", "_build", "from-image.txt"])) == "warm build\n"

      trace = File.read!(trace_file)
      assert trace =~ "ARGV:pull ghcr.io/its-everdred/aiur:latest"
      assert trace =~ "ARGV:run --rm --user"
      assert trace =~ "--volume #{workspace}:/workspace"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace bootstrap image keeps existing warm cache directories" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-bootstrap-image-existing-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("AIUR_TEST_DOCKER_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("AIUR_TEST_DOCKER_TRACE", previous_trace)
    end)

    try do
      fake_bin = Path.join(test_root, "bin")
      workspace_root = Path.join(test_root, "workspaces")
      trace_file = Path.join(test_root, "docker.trace")

      File.mkdir_p!(fake_bin)
      write_fake_docker!(Path.join(fake_bin, "docker"))

      System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))
      System.put_env("AIUR_TEST_DOCKER_TRACE", trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_bootstrap_image: "ghcr.io/its-everdred/aiur:latest"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-IMAGE-EXISTING")
      File.mkdir_p!(Path.join([workspace, "src", "deps"]))
      File.mkdir_p!(Path.join([workspace, "src", "_build"]))
      File.write!(Path.join([workspace, "src", "deps", "keep.txt"]), "existing deps\n")
      File.write!(Path.join([workspace, "src", "_build", "keep.txt"]), "existing build\n")

      assert :ok = Workspace.run_before_run_hook(workspace, "MT-IMAGE-EXISTING")

      assert File.read!(Path.join([workspace, "src", "deps", "keep.txt"])) == "existing deps\n"
      assert File.read!(Path.join([workspace, "src", "_build", "keep.txt"])) == "existing build\n"
      refute File.exists?(Path.join([workspace, "src", "deps", "from-image.txt"]))
      refute File.exists?(Path.join([workspace, "src", "_build", "from-image.txt"]))

      trace = File.read!(trace_file)
      refute trace =~ "ARGV:pull "
      assert trace =~ "ARGV:run --rm"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace removes all workspaces for a closed issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-issue-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join([workspace_root, "project", "S_1"])

      untouched_workspace =
        Path.join([workspace_root, "project", "OTHER-#{System.unique_integer([:positive])}"])

      File.mkdir_p!(target_workspace)
      File.mkdir_p!(untouched_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "stale")
      File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert :ok = Workspace.remove_issue_workspaces("S_1")
      refute File.exists?(target_workspace)
      assert File.exists?(untouched_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup handles missing workspace root" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-missing-workspaces-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert :ok = Workspace.remove_issue_workspaces("S-2")
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert :ok = Workspace.remove_issue_workspaces(nil)
  end

  test "linear issue helpers" do
    issue = %Issue{
      id: "abc",
      labels: ["frontend", "infra"],
      assigned_to_worker: false
    }

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    refute issue.assigned_to_worker
  end

  test "linear client normalizes blockers from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "assignee" => %{
        "id" => "user-1"
      },
      "labels" => %{"nodes" => [%{"name" => "Backend"}]},
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Done"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.labels == ["backend"]
    assert issue.priority == 2
    assert issue.state == "Todo"
    assert issue.assignee_id == "user-1"
    assert issue.assigned_to_worker
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-2"
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    refute issue.assigned_to_worker
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      %Issue{id: "issue-1", identifier: "MT-1"},
      %Issue{id: "issue-2", identifier: "MT-2"}
    ]

    issue_page_2 = [
      %Issue{id: "issue-3", identifier: "MT-3"}
    ]

    merged = Client.merge_issue_pages_for_test([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client paginates issue state fetches by id beyond one page" do
    issue_ids = Enum.map(1..55, &"issue-#{&1}")
    first_batch_ids = Enum.take(issue_ids, 50)
    second_batch_ids = Enum.drop(issue_ids, 50)

    raw_issue = fn issue_id ->
      suffix = String.replace_prefix(issue_id, "issue-", "")

      %{
        "id" => issue_id,
        "identifier" => "MT-#{suffix}",
        "title" => "Issue #{suffix}",
        "description" => "Description #{suffix}",
        "state" => %{"name" => "In Progress"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }
    end

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_states_page, query, variables})

      body = %{
        "data" => %{
          "issues" => %{
            "nodes" => Enum.map(variables.ids, raw_issue)
          }
        }
      }

      {:ok, body}
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)

    assert Enum.map(issues, & &1.id) == issue_ids

    assert_receive {:fetch_issue_states_page, query, %{ids: ^first_batch_ids, first: 50, relationFirst: 50}}

    assert query =~ "AiurLinearIssuesById"

    assert_receive {:fetch_issue_states_page, ^query, %{ids: ^second_batch_ids, first: 5, relationFirst: 50}}
  end

  test "linear client logs response bodies for non-200 graphql responses" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 400}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok,
                      %{
                        status: 400,
                        body: %{
                          "errors" => [
                            %{
                              "message" => "Variable \"$ids\" got invalid value",
                              "extensions" => %{"code" => "BAD_USER_INPUT"}
                            }
                          ]
                        }
                      }}
                   end
                 )
      end)

    assert log =~ "Linear GraphQL request failed status=400"
    assert log =~ ~s(body=%{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"})
    assert log =~ "Variable \\\"$ids\\\" got invalid value"
  end

  test "linear client can suppress auth-only graphql response logs" do
    request_fun = fn _payload, _headers ->
      {:ok,
       %{
         status: 401,
         body: %{"errors" => [%{"message" => "Authentication required, not authenticated"}]}
       }}
    end

    auth_log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 401}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: request_fun,
                   quiet_auth_errors?: true
                 )
      end)

    assert auth_log == ""

    outage_log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 500}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok, %{status: 500, body: %{"errors" => [%{"message" => "temporary outage"}]}}}
                   end,
                   quiet_auth_errors?: true
                 )
      end)

    assert outage_log =~ "Linear GraphQL request failed status=500"
    assert outage_log =~ "temporary outage"
  end

  test "orchestrator sorts dispatch by priority then oldest created_at" do
    issue_same_priority_older = %Issue{
      id: "issue-old-high",
      identifier: "MT-200",
      title: "Old high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    issue_same_priority_newer = %Issue{
      id: "issue-new-high",
      identifier: "MT-201",
      title: "New high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-02 00:00:00Z]
    }

    issue_lower_priority_older = %Issue{
      id: "issue-old-low",
      identifier: "MT-199",
      title: "Old lower priority",
      state: "Todo",
      priority: 2,
      created_at: ~U[2025-12-01 00:00:00Z]
    }

    sorted =
      Orchestrator.sort_issues_for_dispatch_for_test([
        issue_lower_priority_older,
        issue_same_priority_newer,
        issue_same_priority_older
      ])

    assert Enum.map(sorted, & &1.identifier) == ["MT-200", "MT-201", "MT-199"]
  end

  test "todo issue with non-terminal blocker is not dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-1",
      identifier: "MT-1001",
      title: "Blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-1", identifier: "MT-1002", state: "In Progress"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-1",
      identifier: "MT-1007",
      title: "Owned elsewhere",
      state: "Todo",
      assigned_to_worker: false
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "todo issue with terminal blockers remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-1",
      identifier: "MT-1003",
      title: "Ready work",
      state: "Todo",
      blocked_by: [%{id: "blocker-2", identifier: "MT-1004", state: "Closed"}]
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "polling does not auto-dispatch when a paused agent reserves the only slot" do
    paused_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: "MT-PAUSED",
      issue: %Issue{id: "issue-paused", identifier: "MT-PAUSED", state: "In Progress"},
      worker_host: nil,
      control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :paused},
      session_id: "thread-MT-PAUSED",
      started_at: DateTime.utc_now()
    }

    state = %Orchestrator.State{
      max_concurrent_agents: 1,
      running: %{"issue-paused" => paused_entry},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    queued = %Issue{id: "queued-1", identifier: "MT-Q1", title: "Q1", state: "Todo"}

    refute Orchestrator.should_dispatch_issue_for_test(queued, state)
  end

  test "per-state slot cap honors the session-aware max, not just the workflow value" do
    # Regression: bumping the global max via ←/→ updated session_max in
    # the orchestrator state, but `state_slots_available?` was calling
    # `Config.max_concurrent_agents_for_state/1`, which falls back to the
    # *static* workflow value. With workflow max=2 and session bump to 5,
    # the in-flight-state count of 2 was tripping the per-state cap of 2
    # and dispatch was rejected — the UI flashed the cap red on every
    # attempt despite the bump.
    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: 2)

    in_progress_entry = fn id ->
      %{
        pid: self(),
        ref: make_ref(),
        identifier: "MT-#{id}",
        issue: %Issue{id: "issue-#{id}", identifier: "MT-#{id}", state: "In Progress"},
        worker_host: nil,
        control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :working},
        session_id: "thread-MT-#{id}",
        started_at: DateTime.utc_now()
      }
    end

    state = %Orchestrator.State{
      max_concurrent_agents: 2,
      session_max_concurrent_agents: 5,
      running: %{
        "issue-a" => in_progress_entry.("A"),
        "issue-b" => in_progress_entry.("B")
      },
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    todo = %Issue{id: "queued-1", identifier: "MT-Q1", title: "Q1", state: "Todo"}

    assert Orchestrator.dispatch_candidate_for_test(todo, state),
           "manual start of a queued ticket must be eligible after a session-max bump"

    assert Orchestrator.should_dispatch_issue_for_test(todo, state),
           "polling must also see the bumped cap as the effective per-state limit"
  end

  test "manual start is eligible when paused holds the slot but active count is below max" do
    # The operator pressing space on a queued ticket bypasses the
    # paused-reserves-slot rule: paused agents do not count against the
    # active cap, so a free slot stays manually claimable. The polling
    # path stays blocked by the prior test.
    paused_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: "MT-PAUSED",
      issue: %Issue{id: "issue-paused", identifier: "MT-PAUSED", state: "In Progress"},
      worker_host: nil,
      control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :paused},
      session_id: "thread-MT-PAUSED",
      started_at: DateTime.utc_now()
    }

    state = %Orchestrator.State{
      max_concurrent_agents: 1,
      running: %{"issue-paused" => paused_entry},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    queued = %Issue{id: "queued-1", identifier: "MT-Q1", title: "Q1", state: "Todo"}

    assert Orchestrator.dispatch_candidate_for_test(queued, state)
  end

  test "dispatch revalidation skips stale todo issue once a non-terminal blocker appears" do
    stale_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: []
    }

    refreshed_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
    }

    fetcher = fn ["blocked-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

    assert skipped_issue.identifier == "MT-1005"

    assert skipped_issue.blocked_by == [
             %{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}
           ]
  end

  test "workspace remove returns error information for missing directory" do
    random_path =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-missing-#{System.unique_integer([:positive])}"
      )

    assert {:ok, []} = Workspace.remove(random_path)
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before_remove.log")
      after_create_counter = Path.join(test_root, "after_create.count")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo after_create > after_create.log\necho call >> \"#{after_create_counter}\"",
        hook_before_remove: "echo before_remove > \"#{before_remove_marker}\""
      )

      config = Config.settings!()
      assert config.hooks.after_create =~ "echo after_create > after_create.log"
      assert config.hooks.before_remove =~ "echo before_remove >"

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert File.read!(Path.join(workspace, "after_create.log")) == "after_create\n"

      assert {:ok, _workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert length(String.split(String.trim(File.read!(after_create_counter)), "\n")) == 1

      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS")
      assert File.read!(before_remove_marker) == "before_remove\n"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-hooks-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo failure && exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails with large output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-hooks-large-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "i=0; while [ $i -lt 3000 ]; do printf a; i=$((i+1)); done; exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-LARGE-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-LARGE-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook times out" do
    previous_timeout = Application.get_env(:aiur, :workspace_hook_timeout_ms)

    on_exit(fn ->
      if is_nil(previous_timeout) do
        Application.delete_env(:aiur, :workspace_hook_timeout_ms)
      else
        Application.put_env(:aiur, :workspace_hook_timeout_ms, previous_timeout)
      end
    end)

    Application.put_env(:aiur, :workspace_hook_timeout_ms, 10)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-hooks-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "sleep 1"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-TIMEOUT")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-TIMEOUT")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "observability.dashboard_writable re-enables dashboard writes" do
    write_workflow_file!(Workflow.workflow_file_path(), observability_writable: true)

    assert :ok = Config.validate!()
    assert Config.settings!().observability.dashboard_writable == true
    assert Config.dashboard_writable?()
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: nil,
      max_concurrent_agents: nil,
      codex_approval_policy: nil,
      codex_thread_sandbox: nil,
      codex_turn_sandbox_policy: nil,
      codex_turn_timeout_ms: nil,
      codex_read_timeout_ms: nil,
      codex_stall_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    config = Config.settings!()
    assert config.tracker.linear.endpoint == "https://api.linear.app/graphql"
    assert config.tracker.linear.api_key == nil
    assert config.tracker.linear.project_slug == nil
    assert config.workspace.root == Path.join(System.tmp_dir!(), "aiur_workspaces")
    assert config.workspace.bootstrap_image == nil
    refute config.workspace.bootstrap_image_pull
    assert config.worker.max_concurrent_agents_per_host == nil
    assert config.agent.max_concurrent_agents == 10

    # Dashboard binds a free loopback port by default so claude remote-control's
    # transcript hook works without explicit server config. Port 0 = OS-assigned;
    # HttpServer.bound_port/0 reports the real port.
    assert config.server.port == 0

    # Dashboard is read-only by default until the parity pass (#371).
    assert config.observability.dashboard_writable == false
    refute Config.dashboard_writable?()

    assert config.agent.codex.command == "codex app-server"

    assert config.agent.codex.approval_policy == "untrusted"

    assert config.agent.codex.thread_sandbox == "workspace-write"

    assert {:ok, canonical_default_workspace_root} =
             Aiur.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "aiur_workspaces"))

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => [canonical_default_workspace_root],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert config.agent.turn_timeout_ms == 3_600_000
    assert config.agent.codex.read_timeout_ms == 5_000
    assert config.agent.stall_timeout_ms == 300_000

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "codex --config 'model=\"gpt-5.5\"' app-server"
    )

    assert Config.settings!().agent.codex.command ==
             "codex --config 'model=\"gpt-5.5\"' app-server"

    explicit_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-explicit-sandbox-root-#{System.unique_integer([:positive])}"
      )

    explicit_workspace = Path.join(explicit_root, "MT-EXPLICIT")
    explicit_cache = Path.join(explicit_workspace, "cache")
    File.mkdir_p!(explicit_cache)
    assert {:ok, canonical_explicit_workspace} = Aiur.PathSafety.canonicalize(explicit_workspace)

    on_exit(fn -> File.rm_rf(explicit_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: explicit_root,
      codex_approval_policy: "on-request",
      codex_thread_sandbox: "workspace-write",
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [explicit_workspace, explicit_cache]
      }
    )

    config = Config.settings!()
    assert config.agent.codex.approval_policy == "on-request"
    assert config.agent.codex.thread_sandbox == "workspace-write"

    expected_explicit_roots =
      append_unique([explicit_workspace, explicit_cache], canonical_explicit_workspace)

    assert Config.codex_turn_sandbox_policy(explicit_workspace) == %{
             "type" => "workspaceWrite",
             "writableRoots" => expected_explicit_roots
           }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ",")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_concurrent_agents"

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "worker.max_concurrent_agents_per_host"

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.turn_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_read_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "read_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.stall_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: %{todo: true},
      tracker_terminal_states: %{done: true},
      poll_interval_seconds: %{bad: true},
      workspace_root: 123,
      max_retry_backoff_ms: 0,
      max_concurrent_agents_by_state: %{"Todo" => "1", "Review" => 0, "Done" => "bad"},
      hook_timeout_ms: 0,
      observability_enabled: "maybe",
      observability_refresh_ms: %{bad: true},
      observability_render_interval_ms: %{bad: true},
      server_port: -1,
      server_host: 123
    )

    assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "")
    assert :ok = Config.validate!()
    assert Config.settings!().agent.codex.approval_policy == ""
    assert {:error, {:invalid_codex_approval_policy, ""}} = Config.codex_runtime_settings()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "")
    assert :ok = Config.validate!()
    assert Config.settings!().agent.codex.thread_sandbox == ""

    write_workflow_file!(Workflow.workflow_file_path(), workspace_bootstrap_image: "")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "workspace.bootstrap_image"

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_sandbox_policy: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_sandbox_policy"

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "future-policy",
      codex_thread_sandbox: "future-sandbox",
      codex_turn_sandbox_policy: %{
        type: "futureSandbox",
        nested: %{flag: true}
      }
    )

    config = Config.settings!()
    assert config.agent.codex.approval_policy == "future-policy"
    assert config.agent.codex.thread_sandbox == "future-sandbox"

    assert :ok = Config.validate!()

    assert {:error, {:invalid_codex_approval_policy, "future-policy"}} =
             Config.codex_runtime_settings()

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "futureSandbox",
             "nested" => %{"flag" => true}
           }

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server")
    assert Config.settings!().agent.codex.command == "codex app-server"
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "aiur-workspace-root")
    api_key = "resolved-secret"
    codex_bin = Path.join(["~", "bin", "codex"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      workspace_root: "$#{workspace_env_var}",
      codex_command: "#{codex_bin} app-server"
    )

    config = Config.settings!()
    assert config.tracker.linear.api_key == api_key
    assert config.workspace.root == Path.expand(workspace_root)
    assert config.agent.codex.command == "#{codex_bin} app-server"
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "aiur-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    config = Config.settings!()
    assert config.tracker.linear.api_key == "env:#{api_key_env_var}"
    assert config.workspace.root == "env:#{workspace_env_var}"
  end

  test "config supports per-state max concurrent agent overrides" do
    config = """
    agent:
      max_concurrent_agents: 10
      max_concurrent_agents_by_state:
        todo: 1
        "In Progress": 4
        "In Review": 2
    """

    File.write!(Workflow.workflow_file_path(), config)

    assert Config.settings!().agent.max_concurrent_agents == 10
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("In Review") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 2)
    assert :ok = Config.validate!()
    assert Config.settings!().worker.max_concurrent_agents_per_host == 2
  end

  test "schema helpers cover custom type and state limit validation" do
    assert StringOrMap.type() == :map
    assert StringOrMap.embed_as(:json) == :self
    assert StringOrMap.equal?(%{"a" => 1}, %{"a" => 1})
    refute StringOrMap.equal?(%{"a" => 1}, %{"a" => 2})

    assert {:ok, "value"} = StringOrMap.cast("value")
    assert {:ok, %{"a" => 1}} = StringOrMap.cast(%{"a" => 1})
    assert :error = StringOrMap.cast(123)

    assert {:ok, "value"} = StringOrMap.load("value")
    assert :error = StringOrMap.load(123)

    assert {:ok, %{"a" => 1}} = StringOrMap.dump(%{"a" => 1})
    assert :error = StringOrMap.dump(123)

    assert Schema.normalize_state_limits(nil) == %{}

    assert Schema.normalize_state_limits(%{"In Progress" => 2, todo: 1}) == %{
             "todo" => 1,
             "in progress" => 2
           }

    changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"" => 1, "todo" => 0}}, [:limits])
      |> Schema.validate_state_limits(:limits)

    assert changeset.errors == [
             limits: {"state names must not be blank", []},
             limits: {"limits must be positive integers", []}
           ]
  end

  test "agent routing normalizes string levels and rejects bad levels/backends" do
    assert Schema.normalize_agent_routing(nil) == %{}

    assert Schema.normalize_agent_routing(%{"4" => "claude", 5 => :codex}) == %{
             4 => "claude",
             5 => "codex"
           }

    good =
      {%{}, %{routing: :map}}
      |> Changeset.cast(%{routing: %{4 => "claude", 5 => "codex"}}, [:routing])
      |> Schema.validate_agent_routing(:routing)

    assert good.errors == []

    bad =
      {%{}, %{routing: :map}}
      |> Changeset.cast(%{routing: %{0 => "claude", 4 => "bogus"}}, [:routing])
      |> Schema.validate_agent_routing(:routing)

    assert {:routing, {"complexity levels must be positive integers", []}} in bad.errors

    assert Enum.any?(bad.errors, fn
             {:routing, {msg, []}} -> msg =~ "unknown backend"
             _ -> false
           end)

    # backend:model:effort routing values: the backend part must be known,
    # the model suffix is free-form (e.g. complexity:5 -> claude:sonnet).
    assert Schema.split_routing_value("claude") == {"claude", nil}
    assert Schema.split_routing_value("claude:sonnet") == {"claude", "sonnet"}
    assert Schema.split_routing_value("claude:sonnet:high") == {"claude", "sonnet"}
    assert Schema.split_routing_value("claude::high") == {"claude", nil}
    assert Schema.split_routing_value("codex:gpt-5.5") == {"codex", "gpt-5.5"}
    assert Schema.routing_effort("claude:sonnet:high") == "high"
    assert Schema.routing_effort("claude:sonnet:high+remote") == "high"
    assert Schema.routing_effort("claude-repl::xhigh") == "xhigh"
    assert Schema.routing_effort("claude:sonnet") == nil

    with_model =
      {%{}, %{routing: :map}}
      |> Changeset.cast(
        %{
          routing: %{
            3 => "claude:sonnet:high+remote",
            4 => "claude-repl:sonnet:max",
            5 => "codex::high"
          }
        },
        [
          :routing
        ]
      )
      |> Schema.validate_agent_routing(:routing)

    assert with_model.errors == []

    bad_effort =
      {%{}, %{routing: :map}}
      |> Changeset.cast(%{routing: %{4 => "claude:sonnet:high", 5 => "codex:gpt-5.5:max"}}, [
        :routing
      ])
      |> Schema.validate_agent_routing(:routing)

    assert Enum.count(bad_effort.errors) == 2

    assert Enum.any?(bad_effort.errors, fn
             {:routing, {msg, []}} -> msg =~ ~s(invalid effort "high" for backend "claude")
             _ -> false
           end)

    assert Enum.any?(bad_effort.errors, fn
             {:routing, {msg, []}} -> msg =~ ~s(invalid effort "max" for backend "codex")
             _ -> false
           end)

    bad_model_backend =
      {%{}, %{routing: :map}}
      |> Changeset.cast(%{routing: %{4 => "bogus:sonnet"}}, [:routing])
      |> Schema.validate_agent_routing(:routing)

    assert Enum.any?(bad_model_backend.errors, fn
             {:routing, {msg, []}} -> msg =~ "unknown backend"
             _ -> false
           end)

    repl =
      {%{}, %{routing: :map}}
      |> Changeset.cast(%{routing: %{4 => "claude-repl"}}, [:routing])
      |> Schema.validate_agent_routing(:routing)

    assert repl.errors == []

    # `+remote` flag: stripped from backend/model, surfaced by
    # routing_remote_flag?, and only valid on a remote-capable backend.
    assert Schema.split_routing_value("claude:haiku+remote") == {"claude", "haiku"}
    assert Schema.split_routing_value("claude+remote") == {"claude", nil}
    assert Schema.routing_remote_flag?("claude:haiku+remote")
    refute Schema.routing_remote_flag?("claude:haiku")

    remote_ok =
      {%{}, %{routing: :map}}
      |> Changeset.cast(%{routing: %{1 => "claude:haiku+remote"}}, [:routing])
      |> Schema.validate_agent_routing(:routing)

    assert remote_ok.errors == []

    remote_bad =
      {%{}, %{routing: :map}}
      |> Changeset.cast(%{routing: %{1 => "codex:gpt-5.4+remote"}}, [:routing])
      |> Schema.validate_agent_routing(:routing)

    assert Enum.any?(remote_bad.errors, fn
             {:routing, {msg, []}} -> msg =~ "remote-capable backend"
             _ -> false
           end)
  end

  test "agent routing resolves backend model and effort per complexity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "codex",
      agent_routing: %{4 => "claude-repl:sonnet:max", 5 => "codex::high"}
    )

    claude_issue = %Issue{labels: ["complexity:4"]}
    codex_issue = %Issue{labels: ["complexity:5"]}

    assert CodingAgent.backend_for(claude_issue) == "claude-repl"
    assert CodingAgent.model_for(claude_issue) == "sonnet"
    assert CodingAgent.effort_for(claude_issue) == "max"

    assert CodingAgent.backend_for(codex_issue) == "codex"
    assert CodingAgent.model_for(codex_issue) == nil
    assert CodingAgent.effort_for(codex_issue) == "high"

    override_issue = %Issue{labels: ["complexity:4", "model:codex-gpt-5.5"]}
    assert CodingAgent.backend_for(override_issue) == "codex"
    assert CodingAgent.model_for(override_issue) == "gpt-5.5"
    assert CodingAgent.effort_for(override_issue) == nil
  end

  test "remote_control opt-in defaults OFF and parses an explicit true" do
    # Setting #2 is orthogonal to :kind; the default is the single flip
    # point for always-remote, so a fresh parse must land on false.
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.agent.remote_control == false

    assert {:ok, settings} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{remote_control: true}})

    assert settings.agent.remote_control == true
  end

  test "max_log_history_mb defaults to 1000 and validates positivity" do
    # The retention sweep reads this cap; an unset config must land on the
    # built-in 1000 MB default, an explicit value must round-trip, and a
    # non-positive cap must be rejected (it would wipe everything).
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.max_log_history_mb == 1000

    assert {:ok, settings} =
             Schema.parse(%{tracker: %{kind: "memory"}, max_log_history_mb: 250})

    assert settings.max_log_history_mb == 250

    assert {:error, {:invalid_workflow_config, _}} =
             Schema.parse(%{tracker: %{kind: "memory"}, max_log_history_mb: 0})
  end

  test "agent.max_load_average defaults to protected, casts integers, preserves explicit disable" do
    # The CPU load gate (#465) is default-on: an absent key must yield the
    # conservative per-scheduler threshold, an explicit YAML null must still
    # disable the gate, an explicit value must round-trip as a float, a
    # YAML-written integer must cast (not error), and a non-positive threshold
    # must be rejected (it would stall all dispatch).
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.agent.max_load_average == 1.5

    assert {:ok, settings} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{max_load_average: nil}})

    assert settings.agent.max_load_average == nil

    # Real YAML loads arrive string-keyed; the explicit null must survive
    # drop_nil_values on that production shape too, not just the atom-keyed map.
    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "agent" => %{"max_load_average" => nil}
             })

    assert settings.agent.max_load_average == nil

    assert {:ok, settings} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{max_load_average: 1.5}})

    assert settings.agent.max_load_average == 1.5

    assert {:ok, settings} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{max_load_average: 2}})

    assert settings.agent.max_load_average == 2.0

    assert {:error, {:invalid_workflow_config, _}} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{max_load_average: 0}})
  end

  test "agent.synthetic_load_process_cap defaults to derived nil and validates non-negative" do
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.agent.synthetic_load_process_cap == nil

    assert Aiur.Config.default_synthetic_load_process_cap(12) == 3
    assert Aiur.Config.default_synthetic_load_process_cap(2) == 1

    assert {:ok, settings} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{synthetic_load_process_cap: 0}})

    assert settings.agent.synthetic_load_process_cap == 0

    assert {:ok, settings} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{synthetic_load_process_cap: 5}})

    assert settings.agent.synthetic_load_process_cap == 5

    assert {:error, {:invalid_workflow_config, _}} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{synthetic_load_process_cap: -1}})
  end

  test "prewarm defaults to disabled and validates poll_seconds" do
    # Pre-warm is opt-in: an absent block must yield disabled + no base_build +
    # no polling (byte-for-byte back-compat), an explicit block must round-trip,
    # and a negative poll interval must be rejected.
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.prewarm.enabled == false
    assert settings.prewarm.base_build == nil
    assert settings.prewarm.poll_seconds == 0

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{kind: "memory"},
               prewarm: %{enabled: true, base_build: "mise exec -- mix compile", poll_seconds: 30}
             })

    assert settings.prewarm.enabled == true
    assert settings.prewarm.base_build == "mise exec -- mix compile"
    assert settings.prewarm.poll_seconds == 30

    assert {:error, {:invalid_workflow_config, _}} =
             Schema.parse(%{tracker: %{kind: "memory"}, prewarm: %{poll_seconds: -1}})
  end

  test "alerts default to enabled with OS sounds off (back-compat) and round-trip overrides" do
    # Back-compat hard requirement: a machine with no `alerts:` section keeps
    # playing its existing alerts.yaml + ~/alerts sounds, so the defaults must be
    # enabled + OS-default sounds OFF. An explicit block must round-trip.
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.alerts.enabled == true
    assert settings.alerts.use_os_default_sounds == false
    assert settings.alerts.sound_dir == nil
    assert settings.alerts.alerts_file == nil

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{kind: "memory"},
               alerts: %{
                 enabled: false,
                 use_os_default_sounds: true,
                 sound_dir: "~/alerts",
                 alerts_file: "alerts.yaml"
               }
             })

    assert settings.alerts.enabled == false
    assert settings.alerts.use_os_default_sounds == true
    assert settings.alerts.sound_dir == "~/alerts"
    assert settings.alerts.alerts_file == "alerts.yaml"
  end

  test "debug defaults to false and parses an explicit true" do
    # `debug: true` is the config-driven equivalent of the `--debug` flag;
    # an unset config must stay off, an explicit true must round-trip.
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.debug == false

    assert {:ok, settings} =
             Schema.parse(%{tracker: %{kind: "memory"}, debug: true})

    assert settings.debug == true
  end

  test "agent.max_agent_duration_minutes defaults to 60 and rejects negatives" do
    # Safety-net cap the orchestrator's overrun watchdog reads; 0 disables.
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "memory"}})
    assert settings.agent.max_agent_duration_minutes == 60

    assert {:ok, settings} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{max_agent_duration_minutes: 0}})

    assert settings.agent.max_agent_duration_minutes == 0

    assert {:error, {:invalid_workflow_config, _}} =
             Schema.parse(%{tracker: %{kind: "memory"}, agent: %{max_agent_duration_minutes: -1}})
  end

  test "complexity prompts normalize string levels and reject bad levels/values" do
    assert Schema.normalize_complexity_prompts(nil) == %{}

    assert Schema.normalize_complexity_prompts(%{"3" => "medium guidance", 5 => "be careful"}) ==
             %{
               3 => "medium guidance",
               5 => "be careful"
             }

    good =
      {%{}, %{complexity_prompts: :map}}
      |> Changeset.cast(%{complexity_prompts: %{3 => "guidance"}}, [:complexity_prompts])
      |> Schema.validate_complexity_prompts(:complexity_prompts)

    assert good.errors == []

    bad =
      {%{}, %{complexity_prompts: :map}}
      |> Changeset.cast(%{complexity_prompts: %{0 => "x", 4 => 99}}, [:complexity_prompts])
      |> Schema.validate_complexity_prompts(:complexity_prompts)

    assert {:complexity_prompts, {"complexity levels must be positive integers", []}} in bad.errors
    assert {:complexity_prompts, {"complexity prompt values must be strings", []}} in bad.errors
  end

  test "schema parse normalizes policy keys and env-backed fallbacks" do
    missing_workspace_env = "SYMP_MISSING_WORKSPACE_#{System.unique_integer([:positive])}"
    empty_secret_env = "SYMP_EMPTY_SECRET_#{System.unique_integer([:positive])}"
    missing_secret_env = "SYMP_MISSING_SECRET_#{System.unique_integer([:positive])}"

    previous_missing_workspace_env = System.get_env(missing_workspace_env)
    previous_empty_secret_env = System.get_env(empty_secret_env)
    previous_missing_secret_env = System.get_env(missing_secret_env)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    System.delete_env(missing_workspace_env)
    System.put_env(empty_secret_env, "")
    System.delete_env(missing_secret_env)
    System.put_env("LINEAR_API_KEY", "fallback-linear-token")

    on_exit(fn ->
      restore_env(missing_workspace_env, previous_missing_workspace_env)
      restore_env(empty_secret_env, previous_empty_secret_env)
      restore_env(missing_secret_env, previous_missing_secret_env)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{linear: %{api_key: "$#{empty_secret_env}"}},
               workspace: %{root: "$#{missing_workspace_env}"},
               agent: %{codex: %{approval_policy: %{reject: %{sandbox_approval: true}}}}
             })

    assert settings.tracker.linear.api_key == nil
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "aiur_workspaces")

    assert settings.agent.codex.approval_policy == %{
             "reject" => %{"sandbox_approval" => true}
           }

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{linear: %{api_key: "$#{missing_secret_env}"}},
               workspace: %{root: ""}
             })

    assert settings.tracker.linear.api_key == "fallback-linear-token"
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "aiur_workspaces")
  end

  test "schema resolves sandbox policies from explicit and default workspaces" do
    explicit_policy = %{"type" => "workspaceWrite", "writableRoots" => ["/tmp/explicit"]}

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             agent: %Schema.Agent{codex: %Codex{turn_sandbox_policy: explicit_policy}},
             workspace: %Schema.Workspace{root: "/tmp/ignored"}
           }) == explicit_policy

    assert Schema.resolve_turn_sandbox_policy(
             %Schema{
               agent: %Schema.Agent{codex: %Codex{turn_sandbox_policy: explicit_policy}},
               workspace: %Schema.Workspace{root: "/tmp/ignored"}
             },
             "/tmp/workspace"
           ) == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["/tmp/explicit", Path.expand("/tmp/workspace")]
           }

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             agent: %Schema.Agent{codex: %Codex{turn_sandbox_policy: nil}},
             workspace: %Schema.Workspace{root: ""}
           }) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand(Path.join(System.tmp_dir!(), "aiur_workspaces"))],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Schema.resolve_turn_sandbox_policy(
             %Schema{
               agent: %Schema.Agent{codex: %Codex{turn_sandbox_policy: nil}},
               workspace: %Schema.Workspace{root: "/tmp/ignored"}
             },
             "/tmp/workspace"
           ) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("/tmp/workspace")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             agent: %Schema.Agent{
               codex: %Codex{thread_sandbox: "danger-full-access", turn_sandbox_policy: nil}
             },
             workspace: %Schema.Workspace{root: "/tmp/ignored"}
           }) == %{"type" => "dangerFullAccess"}

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             agent: %Schema.Agent{
               codex: %Codex{
                 thread_sandbox: "danger-full-access",
                 turn_sandbox_policy: explicit_policy
               }
             },
             workspace: %Schema.Workspace{root: "/tmp/ignored"}
           }) == explicit_policy
  end

  test "schema keeps workspace roots raw while sandbox helpers expand only for local use" do
    assert {:ok, settings} =
             Schema.parse(%{
               workspace: %{root: "~/.aiur-workspaces"},
               agent: %{codex: %{}}
             })

    assert settings.workspace.root == "~/.aiur-workspaces"

    assert Schema.resolve_turn_sandbox_policy(settings) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("~/.aiur-workspaces")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert {:ok, remote_policy} =
             Schema.resolve_runtime_turn_sandbox_policy(settings, nil, remote: true)

    assert remote_policy == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["~/.aiur-workspaces"],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "runtime sandbox policy resolution augments explicit workspaceWrite policies" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-runtime-sandbox-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-100")
      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: ["relative/path"],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)
      assert {:ok, canonical_issue_workspace} = Aiur.PathSafety.canonicalize(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => ["relative/path", canonical_issue_workspace],
               "networkAccess" => true
             }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "futureSandbox",
          nested: %{flag: true}
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "futureSandbox",
               "nested" => %{"flag" => true}
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "path safety returns errors for invalid path segments" do
    invalid_segment = String.duplicate("a", 300)
    path = Path.join(System.tmp_dir!(), invalid_segment)
    expanded_path = Path.expand(path)

    assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
             Aiur.PathSafety.canonicalize(path)
  end

  test "runtime sandbox policy resolution defaults and augments workspaceWrite policies" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-runtime-sandbox-branches-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-101")

      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      settings = Config.settings!()

      assert {:ok, canonical_workspace_root} =
               Aiur.PathSafety.canonicalize(workspace_root)

      assert {:ok, default_policy} = Schema.resolve_runtime_turn_sandbox_policy(settings)
      assert default_policy["type"] == "workspaceWrite"
      assert default_policy["writableRoots"] == [canonical_workspace_root]

      assert {:ok, blank_workspace_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, "")

      assert blank_workspace_policy == default_policy

      workspace_write_settings = %{
        settings
        | agent: %{
            settings.agent
            | codex: %{
                settings.agent.codex
                | turn_sandbox_policy: %{
                    "type" => "workspaceWrite",
                    "writableRoots" => ["relative/path"]
                  }
              }
          }
      }

      assert {:ok, workspace_write_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(
                 workspace_write_settings,
                 issue_workspace
               )

      assert {:ok, canonical_issue_workspace} = Aiur.PathSafety.canonicalize(issue_workspace)

      assert workspace_write_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => ["relative/path", canonical_issue_workspace]
             }

      remote_workspace = "/remote/workspaces/MT-101"

      assert {:ok, remote_workspace_write_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(
                 workspace_write_settings,
                 remote_workspace,
                 remote: true
               )

      assert remote_workspace_write_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => ["relative/path", remote_workspace]
             }

      read_only_settings = %{
        settings
        | agent: %{
            settings.agent
            | codex: %{
                settings.agent.codex
                | turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => true}
              }
          }
      }

      assert {:ok, %{"type" => "readOnly", "networkAccess" => true}} =
               Schema.resolve_runtime_turn_sandbox_policy(read_only_settings, 123)

      future_settings = %{
        settings
        | agent: %{
            settings.agent
            | codex: %{
                settings.agent.codex
                | thread_sandbox: "danger-full-access",
                  turn_sandbox_policy: %{"type" => "futureSandbox", "nested" => %{"flag" => true}}
              }
          }
      }

      assert {:ok, %{"type" => "futureSandbox", "nested" => %{"flag" => true}}} =
               Schema.resolve_runtime_turn_sandbox_policy(future_settings, 123)

      danger_settings = %{
        settings
        | agent: %{
            settings.agent
            | codex: %{
                settings.agent.codex
                | thread_sandbox: "danger-full-access",
                  turn_sandbox_policy: nil
              }
          }
      }

      assert {:ok, %{"type" => "dangerFullAccess"}} =
               Schema.resolve_runtime_turn_sandbox_policy(danger_settings, 123)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_thread_sandbox: "danger-full-access",
        codex_turn_sandbox_policy: nil
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)
      assert runtime_settings.thread_sandbox == "danger-full-access"
      assert runtime_settings.turn_sandbox_policy == %{"type" => "dangerFullAccess"}

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_thread_sandbox: "danger-full-access",
        codex_turn_sandbox_policy: %{
          type: "futureSandbox",
          nested: %{flag: true}
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "futureSandbox",
               "nested" => %{"flag" => true}
             }

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, 123}}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, 123)
    after
      File.rm_rf(test_root)
    end
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as codex instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end

  test "remote workspace lifecycle uses ssh host aliases from worker config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-remote-workspace-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      workspace_root = "~/.aiur-remote-workspaces"
      workspace_path = "/remote/home/.aiur-remote-workspaces/MT-SSH-WS"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/aiur-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *"__AIUR_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__AIUR_WORKSPACE__' '1' '#{workspace_path}'
          ;;
      esac

      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01:2200"],
        hook_before_run: "echo before-run",
        hook_after_run: "echo after-run",
        hook_before_remove: "echo before-remove"
      )

      assert Config.settings!().worker.ssh_hosts == ["worker-01:2200"]
      assert Config.settings!().workspace.root == workspace_root
      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_before_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_after_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.remove_issue_workspaces("MT-SSH-WS", "worker-01:2200")

      trace = File.read!(trace_file)
      assert trace =~ "-p 2200 worker-01 bash -lc"
      assert trace =~ "__AIUR_WORKSPACE__"
      assert trace =~ "~/.aiur-remote-workspaces/project/MT-SSH-WS"
      assert trace =~ "${workspace#~/}"
      assert trace =~ "echo before-run"
      assert trace =~ "echo after-run"
      assert trace =~ "echo before-remove"
      assert trace =~ "rm -rf"
      assert trace =~ workspace_path
    after
      File.rm_rf(test_root)
    end
  end

  defp bootstrap_dirty_refresh_workspace!(test_root, identifier) do
    source_repo = Path.join(test_root, "source")
    remote_repo = Path.join(test_root, "remote.git")
    workspace_root = Path.join(test_root, "workspaces")
    trace_file = Path.join(test_root, "before-run.trace")

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
      git clone #{shell_quote(remote_repo)} .
      issue_id="$(basename "$PWD")"
      git checkout -b "aiur/${issue_id}" origin/main
      """,
      hook_before_run: """
      printf 'attempt\\n' >> #{shell_quote(trace_file)}
      if [ ! -d .git ] || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        find . -mindepth 1 -maxdepth 1 -exec rm -rf {} +
        git clone #{shell_quote(remote_repo)} .
        issue_id="$(basename "$PWD")"
        git checkout -b "aiur/${issue_id}" origin/main
      else
        git fetch origin main
        if ! git diff --quiet -- . || ! git diff --cached --quiet -- .; then
          echo "Refusing to refresh workspace from origin/main because tracked source changes are present." >&2
          echo "Commit or resolve the workspace changes before resuming this agent." >&2
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

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp write_fake_docker!(path) do
    File.write!(path, """
    #!/bin/sh
    trace_file="${AIUR_TEST_DOCKER_TRACE:-/tmp/aiur-fake-docker.trace}"
    printf 'ARGV:%s\\n' "$*" >> "$trace_file"

    if [ "$1" = "pull" ]; then
      exit 0
    fi

    if [ "$1" != "run" ]; then
      exit 9
    fi

    workspace=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --volume)
          shift
          mount="$1"
          workspace="${mount%:/workspace}"
          ;;
      esac
      shift || true
    done

    if [ -n "$workspace" ]; then
      if [ ! -e "$workspace/src/deps" ]; then
        mkdir -p "$workspace/src/deps"
        printf 'warm deps\\n' > "$workspace/src/deps/from-image.txt"
      fi

      if [ ! -e "$workspace/src/_build" ]; then
        mkdir -p "$workspace/src/_build"
        printf 'warm build\\n' > "$workspace/src/_build/from-image.txt"
      fi
    fi

    exit 0
    """)

    File.chmod!(path, 0o755)
  end

  defp append_unique(values, value) do
    if value in values, do: values, else: values ++ [value]
  end
end
