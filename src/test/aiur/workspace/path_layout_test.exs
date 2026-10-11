defmodule Aiur.WorkspacePathLayoutTest do
  use Aiur.TestSupport

  test "workspace path is deterministic per issue identifier" do
    workspace_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-deterministic")

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det")
    assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det")

    assert first_workspace == second_workspace
    assert Path.basename(first_workspace) == "MT_Det"
  end

  test "workspace path is namespaced by repo so issue numbers do not collide across repos" do
    workspace_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-repo-namespace")

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
    workspace_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-idempotent")

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
    workspace_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-memory-flat")

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
    workspace_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-reuse")

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
    workspace_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-stale-path")

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
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-symlink")

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
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-root-symlink")

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
    workspace_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-root-remove")

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
    workspace_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-hook-failure")

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

  test "workspace remove returns error information for missing directory" do
    random_path = Aiur.TestSupport.tmp_root!("aiur-elixir-missing")

    assert {:ok, []} = Workspace.remove(random_path)
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-hooks")

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
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-hooks-fail")

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
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-hooks-large-fail")

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

    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-hooks-timeout")

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

  test "remote workspace lifecycle uses ssh host aliases from worker config" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-remote-workspace")

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

      assert trace =~
               "-o SetEnv=BASH_ENV=/dev/null ENV=/dev/null HOME=/dev/null ZDOTDIR=/dev/null -p 2200 worker-01"

      assert trace =~ "env -u BASH_ENV -u ENV ZDOTDIR=/dev/null HOME=\"$AIUR_REMOTE_HOME\" bash -c"
      assert trace =~ "__AIUR_WORKSPACE__"
      assert trace =~ "~/.aiur-remote-workspaces/project/MT-SSH-WS"
      assert trace =~ "${workspace#\\~/}"
      assert trace =~ "echo before-run"
      assert trace =~ "echo after-run"
      assert trace =~ "echo before-remove"
      assert trace =~ "rm -rf"
      assert trace =~ workspace_path
    after
      File.rm_rf(test_root)
    end
  end
end
