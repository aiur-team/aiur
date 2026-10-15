defmodule Aiur.Regression.WorkspaceLifecycleLayoutTest do
  use Aiur.TestSupport

  alias Aiur.PathSafety

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
    Aiur.TestSupport.tmp_root!("aiur-reg-wslc-#{short_name}")
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

  defp git!(args) do
    {output, 0} = System.cmd("git", args, stderr_to_stdout: true)
    output
  end
end
