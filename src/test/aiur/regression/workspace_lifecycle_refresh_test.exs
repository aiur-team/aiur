defmodule Aiur.Regression.WorkspaceLifecycleRefreshTest do
  use Aiur.TestSupport

  alias Aiur.AgentGitHubGuard
  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.Workspace.WipPreservation

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
        assert trace_count(trace_file, issue.identifier) == 1
      after
        File.rm_rf(test_root)
      end
    end

    test "dirty leftover + todo state: saved, recreated and disclosed to the worker" do
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

        assert_stale_refresh_saved!(workspace, issue.identifier, trace_file, issue)
      after
        File.rm_rf(test_root)
      end
    end

    test "dirty leftover + agent:todo label on in-progress retry: saved, recreated and disclosed" do
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

        assert_stale_refresh_saved!(workspace, issue.identifier, trace_file, issue)
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
        assert trace_count(trace_file, issue.identifier) == 1
      after
        File.rm_rf(test_root)
      end
    end

    test "dirty stale recreation is recognized by exit 65, never by output wording" do
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

        assert_stale_refresh_saved!(workspace, issue.identifier, trace_file, issue)
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
          basename "$PWD" >> #{shell_quote(trace_file)}
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
        assert trace_count(trace_file, issue.identifier) == 1
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

  describe "agent support after restart (#2697)" do
    # End to end: the Refresh reinstall and the dispatch check both restore these
    # pieces, so either one alone keeps this green. RefreshTest's exit-65 test
    # proves the Refresh reinstall on its own.
    test "restart dispatch retains dirty workspace and its full .aiur-runtime" do
      test_root = test_root("restart-support")

      try do
        {workspace, trace_file} = bootstrap_dirty_refresh_workspace!(test_root, "REG-2697-1")
        assert AgentGitHubGuard.missing_workspace_support(workspace) == []

        issue = %Issue{
          id: "issue-2697-1",
          identifier: "REG-2697-1",
          title: "Recreated at restart",
          state: "todo",
          labels: ["agent:todo"]
        }

        # The restart dispatch order in AgentRunner reuses the existing checkout.
        # Recreate saves the WIP, rebuilds the checkout, and restores agent support.
        assert {:ok, ^workspace} = Workspace.create_for_issue(issue)
        assert_stale_refresh_saved!(workspace, issue.identifier, trace_file, issue)

        assert_full_agent_runtime!(workspace)
        assert String.trim(git!(["-C", workspace, "status", "--short"])) == ""
      after
        File.rm_rf(test_root)
      end
    end

    test "dispatch repairs a ready workspace that lost its GitHub command dir, gh config and quota dir" do
      test_root = test_root("support-repair")

      try do
        {workspace, _trace_file} = bootstrap_dirty_refresh_workspace!(test_root, "REG-2697-2")
        git!(["-C", workspace, "checkout", "--", "README.md"])

        for relative <- [".aiur-runtime/bin", ".aiur-runtime/gh", ".aiur-runtime/github-quota"] do
          File.rm_rf!(Path.join(workspace, relative))
        end

        issue = %Issue{
          id: "issue-2697-2",
          identifier: "REG-2697-2",
          title: "Support vanished",
          state: "in-progress",
          labels: ["agent:in-progress"]
        }

        assert :ok = Workspace.run_before_run_hook(workspace, issue)
        assert_full_agent_runtime!(workspace)
      after
        File.rm_rf(test_root)
      end
    end

    test "dispatch refuses with a named reason when the gh config dir cannot be repaired" do
      test_root = test_root("support-refuse")

      try do
        {workspace, _trace_file} = bootstrap_dirty_refresh_workspace!(test_root, "REG-2697-3")
        git!(["-C", workspace, "checkout", "--", "README.md"])

        # An agent-planted symlink must never count as the gh config dir.
        gh_config = AgentGitHubGuard.gh_config_dir(workspace)
        operator_config = Path.join(test_root, "operator-gh")
        File.mkdir_p!(operator_config)
        File.rm_rf!(gh_config)
        File.ln_s!(operator_config, gh_config)

        issue = %Issue{
          id: "issue-2697-3",
          identifier: "REG-2697-3",
          title: "Unsafe gh config",
          state: "in-progress",
          labels: ["agent:in-progress"]
        }

        Publisher.set_tracked_fn(fn _ -> true end)
        :ok = Exchange.subscribe("ticket.REG-2697-3.workspace.agent_support_incomplete")

        assert {:error, {:agent_support_repair_failed, ^workspace, missing, {:agent_gh_config_dir_unavailable, _, _}}} =
                 Workspace.run_before_run_hook(workspace, issue)

        assert ".aiur-runtime/gh" in missing
        assert_receive {:event, %{topic: "ticket.REG-2697-3.workspace.agent_support_incomplete"} = event}, 500
        assert event["message"] =~ ".aiur-runtime/gh"

        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      after
        File.rm_rf(test_root)
      end
    end
  end

  defp test_root(short_name) do
    Aiur.TestSupport.tmp_root!("aiur-reg-wslc-#{short_name}")
  end

  defp assert_full_agent_runtime!(workspace) do
    runtime = Path.join(workspace, ".aiur-runtime")

    for command <- ~w(gh git aiur-github-budget) do
      path = Path.join([runtime, "bin", command])
      assert %File.Stat{type: :regular, mode: mode} = File.lstat!(path), "missing #{path}"
      assert Bitwise.band(mode, 0o111) != 0, "not executable: #{path}"
    end

    for command <- ~w(elixir mix mise) do
      assert File.regular?(Path.join([runtime, "build-bin", command]))
    end

    for directory <- ~w(gh github-quota tmp) do
      assert %File.Stat{type: :directory} = File.lstat!(Path.join(runtime, directory)), "missing #{directory}/"
    end

    assert AgentGitHubGuard.missing_workspace_support(workspace) == []
    assert File.dir?(Path.join([workspace, ".claude", "skills", "aiur-agent"]))
  end

  # A before_run still in flight from another test runs this hook too (the
  # command is VM-global config), so count only this workspace's leaf (#4008).
  defp trace_count(trace_file, identifier) do
    trace_file |> File.read!() |> String.split("\n", trim: true) |> Enum.count(&(&1 == identifier))
  end

  defp assert_stale_refresh_saved!(workspace, identifier, trace_file, issue) do
    assert :ok = Workspace.run_before_run_hook(workspace, issue)
    assert File.read!(Path.join(workspace, "README.md")) == "initial\n"
    assert trace_count(trace_file, identifier) == 2

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
      basename "$PWD" >> #{shell_quote(trace_file)}
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
