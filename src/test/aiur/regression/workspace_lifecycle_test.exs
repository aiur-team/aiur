defmodule Aiur.Regression.WorkspaceLifecycleTest do
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.PathSafety
  alias Aiur.Workspace.Provisioner

  describe "hollow workspace provisioning (#1317)" do
    test "logs-only workspace with no configured before_run hook: dispatch refuses instead of starting a turn" do
      test_root = test_root("hollow-logs-only")

      try do
        root = Path.join(test_root, "workspaces")

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: root
        )

        # No `.git`, no checkout — exactly the state #1306 was dispatched into.
        workspace = Workspace.workspace_path_under(root, "REG-HOLLOW-1")
        File.mkdir_p!(Path.join(workspace, "logs"))
        File.write!(Path.join([workspace, "logs", "agent.ndjson"]), "{}\n")

        issue = %Issue{
          id: "issue-hollow-1",
          identifier: "REG-HOLLOW-1",
          title: "Hollow workspace",
          state: "in-progress",
          labels: ["agent:in-progress"]
        }

        # The contamination filter's tracked_fn is process-global
        # (:persistent_term) and can be left pointed at another test's
        # narrow set; reset it so this ticket's alert isn't silently filtered.
        Publisher.set_tracked_fn(fn _ -> true end)
        :ok = Exchange.subscribe("ticket.REG-HOLLOW-1.workspace.provisioning_incomplete")

        assert {:error, {:workspace_provisioning_incomplete, ^workspace, :bootstrap}} =
                 Workspace.run_before_run_hook(workspace, issue)

        # Refused bootstraps remain eligible for reconstruction on a later retry:
        # installing runtime wrappers here would turn logs-only into unproven WIP.
        assert File.ls!(workspace) == ["logs"]
        refute File.exists?(Path.join(workspace, ".aiur-runtime"))
        assert Provisioner.workspace_readiness(workspace) == :bootstrap

        # The underlying reason is in the alert text itself, not just a fixed
        # "missing" headline the operator would have to grep the log to explain.
        assert_receive {:event, %{topic: "ticket.REG-HOLLOW-1.workspace.provisioning_incomplete"} = event}, 500
        assert event["message"] =~ workspace
        assert event["message"] =~ ":bootstrap"

        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      after
        File.rm_rf(test_root)
      end
    end

    test "a staged before_run clone into a fresh bootstrap workspace lands at the destination" do
      test_root = test_root("hollow-staged-clone")

      try do
        source_repo = Path.join(test_root, "source")
        remote_repo = Path.join(test_root, "remote.git")
        root = Path.join(test_root, "workspaces")

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
          workspace_root: root,
          hook_before_run: """
          git clone #{shell_quote(remote_repo)} .
          issue_id="$(basename "$PWD")"
          git checkout -b "aiur/${issue_id}" origin/main
          """
        )

        # A prior interrupted attempt left only `logs/` behind — no `.git` yet,
        # so before_run's staged reconstruction path runs, exactly like the
        # #1317 incident (hook=before_run, staged, clone succeeds).
        workspace = Workspace.workspace_path_under(root, "REG-STAGED-1")
        File.mkdir_p!(Path.join(workspace, "logs"))
        File.write!(Path.join([workspace, "logs", "agent.ndjson"]), "{}\n")

        issue = %Issue{
          id: "issue-staged-1",
          identifier: "REG-STAGED-1",
          title: "Staged clone lands",
          state: "in-progress",
          labels: ["agent:in-progress"]
        }

        assert :ok = Workspace.run_before_run_hook(workspace, issue)

        assert File.exists?(Path.join(workspace, ".git"))
        assert File.read!(Path.join(workspace, "README.md")) == "initial\n"
        assert File.read!(Path.join([workspace, "logs", "agent.ndjson"])) == "{}\n"
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "create/reuse/recreate at ensure_workspace" do
    test "existing workspace dir is reused as-is; local changes survive" do
      test_root = test_root("reuse")

      try do
        root = Path.join(test_root, "workspaces")

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: root,
          hook_after_create: "echo first > README.md"
        )

        assert {:ok, first_workspace} = Workspace.create_for_issue("REG-REUSE")

        File.write!(Path.join(first_workspace, "README.md"), "changed\n")
        File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")

        assert {:ok, second_workspace} = Workspace.create_for_issue("REG-REUSE")
        assert second_workspace == first_workspace
        assert File.read!(Path.join(second_workspace, "README.md")) == "changed\n"
        assert File.read!(Path.join(second_workspace, "local-progress.txt")) == "in progress\n"
      after
        File.rm_rf(test_root)
      end
    end

    test "stale non-directory path is replaced with a fresh workspace dir" do
      test_root = test_root("stale-path")

      try do
        root = Path.join(test_root, "workspaces")
        stale_path = Path.join([root, "project", "REG-STALE"])
        File.mkdir_p!(Path.dirname(stale_path))
        File.write!(stale_path, "old state\n")

        write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)

        assert {:ok, canonical_stale_path} = PathSafety.canonicalize(stale_path)
        assert {:ok, workspace} = Workspace.create_for_issue("REG-STALE")
        assert workspace == canonical_stale_path
        assert File.dir?(workspace)
      after
        File.rm_rf(test_root)
      end
    end
  end

  defp test_root(short_name) do
    Aiur.TestSupport.tmp_root!("aiur-reg-wslc-#{short_name}")
  end

  defp git!(args) do
    {output, 0} = System.cmd("git", args, stderr_to_stdout: true)
    output
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
