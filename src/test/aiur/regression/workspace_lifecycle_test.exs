defmodule Aiur.Regression.WorkspaceLifecycleTest do
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.PathSafety

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

  describe "before_run refresh/recreate decision table (#569→#577→#653→#661)" do
    test "clean workspace: before_run refreshes and returns :ok without recreate" do
      test_root = test_root("clean")

      try do
        {workspace, trace_file} = bootstrap_dirty_refresh_workspace!(test_root, "REG-CLEAN-1")
        git!(["-C", workspace, "checkout", "--", "README.md"])
        File.rm_rf!(Path.join(workspace, ".claude"))
        File.rm_rf!(Path.join(workspace, ".codex"))

        issue = %Issue{
          id: "issue-clean-1",
          identifier: "REG-CLEAN-1",
          title: "t",
          state: "in-progress",
          labels: ["agent:in-progress"]
        }

        assert :ok = Workspace.run_before_run_hook(workspace, issue)
        assert File.read!(Path.join(workspace, "README.md")) == "initial\n"
        assert String.trim(git!(["-C", workspace, "status", "--short"])) == ""
        assert trace_count(trace_file) == 1
      after
        File.rm_rf(test_root)
      end
    end

    test "dirty leftover + todo state: recreated clean, before_run re-runs exactly once (#577)" do
      test_root = test_root("todo")

      try do
        {workspace, trace_file} = bootstrap_dirty_refresh_workspace!(test_root, "REG-TODO-1")

        issue = %Issue{
          id: "issue-todo-1",
          identifier: "REG-TODO-1",
          title: "Recover stale workspace",
          state: "todo",
          labels: ["agent:todo"]
        }

        assert :ok = Workspace.run_before_run_hook(workspace, issue)
        assert File.read!(Path.join(workspace, "README.md")) == "initial\n"
        assert String.trim(git!(["-C", workspace, "status", "--short"])) == ""
        assert trace_count(trace_file) == 2
      after
        File.rm_rf(test_root)
      end
    end

    test "dirty leftover + agent:todo label on in-progress retry: still recreated (#577 retry path)" do
      test_root = test_root("retry")

      try do
        {workspace, trace_file} = bootstrap_dirty_refresh_workspace!(test_root, "REG-RETRY-1")

        issue = %Issue{
          id: "issue-retry-1",
          identifier: "REG-RETRY-1",
          title: "Recover stale retry workspace",
          state: "in-progress",
          labels: ["agent:todo"]
        }

        assert :ok = Workspace.run_before_run_hook(workspace, issue)
        assert File.read!(Path.join(workspace, "README.md")) == "initial\n"
        assert String.trim(git!(["-C", workspace, "status", "--short"])) == ""
        assert trace_count(trace_file) == 2
      after
        File.rm_rf(test_root)
      end
    end

    test "dirty in-flight WIP: refresh skipped non-fatally, WIP preserved (#653)" do
      test_root = test_root("wip")

      try do
        {workspace, trace_file} = bootstrap_dirty_refresh_workspace!(test_root, "REG-WIP-1")

        issue = %Issue{
          id: "issue-wip-1",
          identifier: "REG-WIP-1",
          title: "Protect resume workspace",
          state: "in-progress",
          labels: ["agent:in-progress"]
        }

        # WHY: before #656, this exit-65 propagated as an error -> 3 retries ->
        # retry_exhausted, so every PR merge (base-branch push fires before_run
        # on live agents) killed every other in-flight agent's uncommitted WIP.
        assert :ok = Workspace.run_before_run_hook(workspace, issue)

        assert File.read!(Path.join(workspace, "README.md")) == "dirty\n"
        assert trace_count(trace_file) == 1
      after
        File.rm_rf(test_root)
      end
    end

    test "refusal is recognized by exit 65, never by output wording" do
      test_root = test_root("exit-65")

      try do
        {workspace, trace_file} =
          bootstrap_dirty_refresh_workspace!(test_root, "REG-65-1", refusal_output: "completely different refusal text")

        issue = %Issue{
          id: "issue-exit-65-1",
          identifier: "REG-65-1",
          title: "Recover stale workspace by exit code",
          state: "todo",
          labels: ["agent:todo"]
        }

        assert :ok = Workspace.run_before_run_hook(workspace, issue)
        assert File.read!(Path.join(workspace, "README.md")) == "initial\n"
        assert String.trim(git!(["-C", workspace, "status", "--short"])) == ""
        assert trace_count(trace_file) == 2
      after
        File.rm_rf(test_root)
      end
    end

    test "non-65 before_run failure is fatal and never recreates, even for a todo dispatch" do
      test_root = test_root("exit-7")

      try do
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
          exit 7
          """
        )

        assert {:ok, workspace} = Workspace.create_for_issue("REG-EXIT-7")
        File.write!(Path.join(workspace, "README.md"), "dirty\n")

        issue = %Issue{
          id: "issue-exit-7",
          identifier: "REG-EXIT-7",
          title: "Fatal hook failure",
          state: "todo",
          labels: ["agent:todo"]
        }

        assert {:error, {:workspace_hook_failed, "before_run", 7, _output}} =
                 Workspace.run_before_run_hook(workspace, issue)

        assert File.read!(Path.join(workspace, "README.md")) == "dirty\n"
        assert trace_count(trace_file) == 1
      after
        File.rm_rf(test_root)
      end
    end

    test "checked-in .aiur/hooks pins exit 65 as the refresh-refusal contract" do
      hooks_path = Path.expand("../../../../.aiur/hooks", __DIR__)
      hooks = File.read!(hooks_path)

      assert hooks =~ "exit 65"
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

  describe "git metadata writability after materialize (#493→#542→#561→#565→#616)" do
    test "materialized workspace repairs all four canonical stale locks" do
      test_root = test_root("locks")

      try do
        base = build_warm_base!(Path.join(test_root, "base"))
        workspace = Path.join(test_root, "561")

        assert :ok = Workspace.materialize_from_base(base, workspace)

        stale_locks = [
          Path.join([workspace, ".git", "index.lock"]),
          Path.join([workspace, ".git", "FETCH_HEAD.lock"]),
          Path.join([workspace, ".git", "ORIG_HEAD.lock"]),
          Path.join([workspace, ".git", "refs", "remotes", "origin", "aiur", "561.lock"])
        ]

        Enum.each(stale_locks, fn lock ->
          File.mkdir_p!(Path.dirname(lock))
          File.write!(lock, "stale\n")
        end)

        assert :ok = Workspace.ensure_git_metadata_writable(workspace)
        assert Enum.all?(stale_locks, &(not File.exists?(&1)))
      after
        File.rm_rf(test_root)
      end
    end

    test "pr- workspace additionally probes the checked-out head-ref lock" do
      test_root = test_root("pr-lock")

      try do
        base = build_warm_base!(Path.join(test_root, "base"))
        workspace = Path.join(test_root, "pr-88")

        assert :ok = Workspace.materialize_from_base(base, workspace, "feature/x")

        stale_lock = Path.join([workspace, ".git", "refs", "remotes", "origin", "feature", "x.lock"])
        File.mkdir_p!(Path.dirname(stale_lock))
        File.write!(stale_lock, "stale\n")

        assert :ok = Workspace.ensure_git_metadata_writable(workspace)
        refute File.exists?(stale_lock)
      after
        File.rm_rf(test_root)
      end
    end

    test "git metadata outside the workspace is rejected with the shaped error" do
      test_root = test_root("external-git")

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "REG-BAD-1")
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

        assert {:error, {:workspace_git_metadata_unwritable, ^workspace, {:git_dir_outside_workspace, rejected}}} =
                 Workspace.run_before_run_hook(workspace, "REG-BAD-1")

        assert {:ok, canonical_external_git_dir} = PathSafety.canonicalize(external_git_dir)
        assert rejected == canonical_external_git_dir
      after
        File.rm_rf(test_root)
      end
    end

    test "non-git workspace passes the writability check (:not_git passthrough)" do
      test_root = test_root("not-git")

      try do
        dir = Path.join(test_root, "plain")
        File.mkdir_p!(dir)

        assert :ok = Workspace.ensure_git_metadata_writable(dir)
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "prewarm materialize fallback to cold clone" do
    test "non-copyable base errors and removes the partial workspace" do
      test_root = test_root("missing-base")

      try do
        workspace = Path.join(test_root, "ws")

        assert {:error, _} = Workspace.materialize_from_base(Path.join(test_root, "missing-base"), workspace)
        refute File.exists?(workspace)
      after
        File.rm_rf(test_root)
      end
    end

    test "materialize branches off the live origin tip, not the stale base HEAD (#567)" do
      test_root = test_root("live-origin")

      try do
        origin = Path.join(test_root, "origin.git")
        git!(["init", "--quiet", "--bare", "-b", "main", origin])

        seed = Path.join(test_root, "seed")
        git!(["clone", "--quiet", origin, seed])
        git!(["-C", seed, "config", "user.email", "t@example.com"])
        git!(["-C", seed, "config", "user.name", "T"])
        File.write!(Path.join(seed, "README.md"), "v1\n")
        git!(["-C", seed, "add", "."])
        git!(["-C", seed, "commit", "--quiet", "-m", "v1"])
        git!(["-C", seed, "push", "--quiet", "origin", "main"])

        base = Path.join(test_root, "freshbase")
        git!(["clone", "--quiet", origin, base])
        File.mkdir_p!(Path.join(base, "_build"))
        File.write!(Path.join(base, "_build/sentinel"), "warm\n")

        File.write!(Path.join(seed, "README.md"), "v2\n")
        git!(["-C", seed, "commit", "--quiet", "-am", "v2"])
        git!(["-C", seed, "push", "--quiet", "origin", "main"])
        v2 = String.trim(git!(["-C", seed, "rev-parse", "HEAD"]))

        workspace = Path.join(test_root, "777")
        assert :ok = Workspace.materialize_from_base(base, workspace)

        assert branch(workspace) == "aiur/777"
        assert String.trim(git!(["-C", workspace, "rev-parse", "HEAD"])) == v2
        assert File.read!(Path.join(workspace, "README.md")) == "v2\n"
        assert File.exists?(Path.join(workspace, "_build/sentinel"))
      after
        File.rm_rf(test_root)
      end
    end

    test "prewarm enabled but base not ready: create_for_issue cold-creates and runs after_create" do
      test_root = test_root("prewarm-gate")

      try do
        root = Path.join(test_root, "workspaces")

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: root,
          hook_after_create: "touch cold-marker"
        )

        path = Workflow.workflow_file_path()
        File.write!(path, File.read!(path) <> "prewarm:\n  enabled: true\n  base_build: \"true\"\n")
        if Process.whereis(Aiur.WorkflowStore), do: Aiur.WorkflowStore.force_reload()

        {phase, _} = Aiur.RepoBase.status()
        refute phase == :ready

        assert {:ok, workspace} = Workspace.create_for_issue("REG-GATE-1")
        assert File.exists?(Path.join(workspace, "cold-marker"))
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "workspace root layout <root>/<repo>/<issue>" do
    test "github repo namespaces the path as <root>/<owner>/<repo>/<issue>" do
      test_root = test_root("github-layout")

      try do
        root = Path.join(test_root, "workspaces")

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "github",
          tracker_repo: "octo/widgets",
          workspace_root: root
        )

        expected = Path.join([root, "octo", "widgets", "10"])
        assert {:ok, canonical_expected} = PathSafety.canonicalize(expected)
        assert {:ok, workspace} = Workspace.create_for_issue("10")
        assert workspace == canonical_expected
        assert Path.basename(workspace) == "10"
      after
        File.rm_rf(test_root)
      end
    end

    test "repo segment append is idempotent when the root already ends with it" do
      test_root = test_root("idempotent-layout")

      try do
        root = Path.join([test_root, "workspaces", "octo", "widgets"])

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "github",
          tracker_repo: "octo/widgets",
          workspace_root: root
        )

        expected = Path.join([root, "10"])
        assert {:ok, canonical_expected} = PathSafety.canonicalize(expected)
        assert {:ok, workspace} = Workspace.create_for_issue("10")
        assert workspace == canonical_expected
      after
        File.rm_rf(test_root)
      end
    end

    test "memory tracker falls back to the flat <root>/<issue> layout" do
      test_root = test_root("memory-layout")

      try do
        root = Path.join(test_root, "workspaces")

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: root
        )

        expected = Path.join(root, "MEM-1")
        assert {:ok, canonical_expected} = PathSafety.canonicalize(expected)
        assert {:ok, workspace} = Workspace.create_for_issue("MEM-1")
        assert workspace == canonical_expected
      after
        File.rm_rf(test_root)
      end
    end

    test "workspace_path_under/2 derives the identical layout without touching disk" do
      test_root = test_root("path-under")

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "github",
          tracker_repo: "octo/widgets",
          workspace_root: Path.join(test_root, "workspaces")
        )

        assert Workspace.workspace_path_under("/x/root", "10") == "/x/root/octo/widgets/10"
        assert Workspace.workspace_path_under("/x/root", "we ird/id") == "/x/root/octo/widgets/we_ird_id"
      after
        File.rm_rf(test_root)
      end
    end

    test "PR-anchored unit gets a pr-<pr#> leaf" do
      test_root = test_root("pr-leaf")

      try do
        root = Path.join(test_root, "workspaces")

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: root
        )

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
        assert Path.basename(workspace) == "pr-77"
      after
        File.rm_rf(test_root)
      end
    end
  end

  defp test_root(short_name) do
    Path.join(
      System.tmp_dir!(),
      "aiur-reg-wslc-#{short_name}-#{System.unique_integer([:positive])}"
    )
  end

  defp trace_count(trace_file) do
    trace_file
    |> File.read!()
    |> String.split("\n", trim: true)
    |> length()
  end

  defp branch(workspace) do
    workspace
    |> then(&git!(["-C", &1, "rev-parse", "--abbrev-ref", "HEAD"]))
    |> String.trim()
  end

  defp build_warm_base!(base) do
    File.mkdir_p!(base)

    git!(["init", "--quiet", "-b", "main", base])
    git!(["-C", base, "config", "user.email", "t@example.com"])
    git!(["-C", base, "config", "user.name", "T"])
    File.write!(Path.join(base, "README.md"), "v1\n")
    File.write!(Path.join(base, ".gitignore"), "_build/\n")
    git!(["-C", base, "add", "."])
    git!(["-C", base, "commit", "--quiet", "-m", "init"])

    File.mkdir_p!(Path.join(base, "_build"))
    File.write!(Path.join(base, "_build/sentinel"), "warm\n")

    base
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

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
