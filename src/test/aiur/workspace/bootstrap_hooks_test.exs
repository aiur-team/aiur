defmodule Aiur.WorkspaceBootstrapHooksTest do
  use Aiur.TestSupport
  alias Aiur.Config.Schema.{AgentValidation, Codex, StringOrMap}

  test "workspace bootstrap can be implemented in after_create hook" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-hook-bootstrap")

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(Path.join(template_repo, "keep"))
      File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
      File.write!(Path.join(template_repo, "README.md"), "hook clone\n")
      File.write!(Path.join(template_repo, ".gitignore"), "tracked-ignore/\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", ".gitignore", "README.md", "keep/file.txt"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 #{template_repo} ."
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-1")
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "hook clone\n"
      assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"

      assert :ok =
               Aiur.AgentEventLog.write(workspace, nil, %{
                 event: "notification",
                 last_message: "workspace log remains readable"
               })

      assert File.read!(Path.join(workspace, ".gitignore")) == "tracked-ignore/\n"

      assert {"", 0} =
               System.cmd("git", ["-C", workspace, "status", "--short", "--", "logs"], stderr_to_stdout: true)

      assert %{path: log_path, messages: messages} = Aiur.AgentLog.read_workspace(workspace)
      assert log_path == Path.join([workspace, "logs", "agent.ndjson"])
      assert Enum.any?(messages, &(&1.body =~ "workspace log remains readable"))
    after
      File.rm_rf(test_root)
    end
  end

  test "create_for_issue uses a pr-<pr#> leaf for a PR-anchored unit (identifier stays <pr#>)" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-pr-anchored-leaf")

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root
      )

      # A synthetic PR-anchored unit: identifier is the bare PR number (the
      # comment topic / resume key) while `pr_head_ref` marks it PR-anchored.
      pr_issue = %Issue{
        id: "pr-77",
        identifier: "77",
        title: "Human PR",
        description: "",
        state: "pr-watch",
        branch_name: "feature/login",
        pr_head_ref: "feature/login",
        labels: []
      }

      assert {:ok, workspace} = Workspace.create_for_issue(pr_issue)

      assert Path.basename(workspace) == "pr-77",
             "PR-anchored workspace leaf must be pr-<pr#>, got #{Path.basename(workspace)}"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace bootstrap supports normal git metadata writes" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-git-metadata")

    try do
      source_repo = Path.join(test_root, "source")
      remote_repo = Path.join(test_root, "remote.git")
      workspace_root = Path.join(test_root, "workspaces")
      cache_root = Path.join(test_root, "cache")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-git-metadata.trace")

      File.mkdir_p!(source_repo)
      File.mkdir_p!(cache_root)
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
      assert {:ok, canonical_git_dir} = Aiur.PathSafety.canonicalize(Path.join(workspace, ".git"))
      assert {:ok, runtime_settings} = Config.codex_runtime_settings(workspace)
      assert cache_root in runtime_settings.turn_sandbox_policy["writableRoots"]
      assert canonical_workspace in runtime_settings.turn_sandbox_policy["writableRoots"]
      assert canonical_git_dir in runtime_settings.turn_sandbox_policy["writableRoots"]
      assert Aiur.BuildGate.gate_dir() in runtime_settings.turn_sandbox_policy["writableRoots"]

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
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-before-run-git-locks")

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

  test "before_run verifies git add can create the index lock before agent turns" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-before-run-git-add-probe")

    previous_path = System.get_env("PATH")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "IDX-1")
      fake_bin = Path.join(test_root, "bin")
      fake_git = Path.join(fake_bin, "git")
      trace_file = Path.join(test_root, "git.trace")

      File.mkdir_p!(Path.join([workspace, ".git", "refs", "remotes", "origin", "aiur"]))
      File.mkdir_p!(fake_bin)
      File.write!(Path.join([workspace, ".git", "index"]), "")

      File.write!(fake_git, """
      #!/bin/sh
      printf '%s\\n' "$*" >> "#{trace_file}"

      case "$*" in
        *"rev-parse --is-inside-work-tree"*)
          printf 'true\\n'
          exit 0
          ;;
        *"rev-parse --git-dir"*)
          printf '.git\\n'
          exit 0
          ;;
        *"add -f -N -- .aiur-git-index-write-probe-"*)
          printf 'fatal: Unable to create index.lock: Operation not permitted\\n' >&2
          exit 128
          ;;
        *"reset -q -- .aiur-git-index-write-probe-"*)
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """)

      File.chmod!(fake_git, 0o755)
      System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root
      )

      assert {:error, {:workspace_git_metadata_unwritable, probe_path, {:git_index_probe_failed, 128, output}}} =
               Workspace.run_before_run_hook(workspace, "IDX-1")

      assert Path.dirname(probe_path) == workspace
      assert Path.basename(probe_path) =~ ".aiur-git-index-write-probe-"
      assert output =~ "index.lock"
      refute File.exists?(probe_path)
    after
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end
  end

  test "before_run git index probe ignores workspace ignore rules" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-before-run-git-ignored-probe")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "IDX-IGNORED")

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, ".gitignore"), ".aiur-*\n")
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", ".gitignore"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "ignore aiur probes"])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root
      )

      assert :ok = Workspace.run_before_run_hook(workspace, "IDX-IGNORED")
      assert {status, 0} = System.cmd("git", ["-C", workspace, "status", "--porcelain"])
      assert status == ""
    after
      File.rm_rf(test_root)
    end
  end

  test "before_run rejects git metadata outside the issue workspace" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-external-gitdir")

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
end
