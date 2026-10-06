defmodule Aiur.Workspace.RefreshTest do
  use Aiur.TestSupport

  alias Aiur.{AgentGitHubGuard, AppServer.Adapter}
  alias Aiur.Workflow
  alias Aiur.Workspace.{Ownership, Refresh}

  setup do
    test_root = Aiur.TestSupport.tmp_root!("refresh_test")
    workspace = Path.join(test_root, "ws")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(test_root) end)
    {:ok, workspace: workspace, test_root: test_root}
  end

  test "maybe_recreate_stale_workspace/6 with non-stale error passes error through", %{workspace: workspace} do
    error = {:error, {:workspace_hook_failed, "before_run", 1, ""}}
    reason = {:workspace_hook_failed, "before_run", 1, ""}
    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}

    assert ^error =
             Refresh.maybe_recreate_stale_workspace(error, reason, "some_cmd", workspace, issue_context, nil)
  end

  test "run/3 with no before_run configured returns :ok", %{workspace: workspace, test_root: test_root} do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: test_root)

    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}
    assert :ok = Refresh.run(workspace, issue_context, nil)
  end

  test "run/3 stages a logs-only workspace before before_run and preserves prior logs", %{
    workspace: workspace,
    test_root: test_root
  } do
    log_path = Path.join([workspace, "logs", "agent.md"])
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, "prior transcript\n")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      hook_before_run:
        "test -z \"$(find . -mindepth 1 -maxdepth 1 -print -quit)\" && git init --quiet -b main && git config user.email t@example.com && git config user.name T && touch rebuilt && git add rebuilt && git commit --quiet -m rebuilt"
    )

    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}
    assert :ok = Refresh.run(workspace, issue_context, nil)

    assert File.exists?(Path.join(workspace, "rebuilt"))
    assert File.read!(log_path) == "prior transcript\n"
    assert File.regular?(Path.join(workspace, ".aiur-runtime/build-bin/mix"))
  end

  test "run/3 refuses incomplete Git WIP before executing before_run", %{
    workspace: workspace,
    test_root: test_root
  } do
    {_output, 0} = System.cmd("git", ["init", "--quiet", workspace], stderr_to_stdout: true)
    notes = Path.join(workspace, "notes.txt")
    before_run_marker = Path.join(test_root, "before-run-ran")
    File.write!(notes, "preserve this interrupted bootstrap\n")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      hook_before_run: "touch #{before_run_marker}"
    )

    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}

    assert {:error, {:workspace_ambiguous, ^workspace, :invalid_git_checkout}} =
             Refresh.run(workspace, issue_context, nil)

    assert File.read!(notes) == "preserve this interrupted bootstrap\n"
    refute File.exists?(before_run_marker)
  end

  test "run/3 exit-65 recreation restores the full agent support tree when checkout is clean", %{
    workspace: workspace,
    test_root: test_root
  } do
    init_repo!(workspace)
    recreate_marker = Path.join(test_root, "recreate-once")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      max_concurrent_builds: 1,
      build_start_stagger_seconds: 0,
      min_free_memory_mb: nil,
      hook_before_run: """
      if [ ! -f #{Aiur.Shell.escape(recreate_marker)} ]; then touch #{Aiur.Shell.escape(recreate_marker)}; exit 65; fi
      test -z "$(find . -mindepth 1 -maxdepth 1 -print -quit)"
      git -C "$PWD" init --quiet -b main
      git -C "$PWD" config user.email t@example.com
      git -C "$PWD" config user.name T
      touch rebuilt
      git -C "$PWD" add rebuilt
      git -C "$PWD" commit --quiet -m rebuilt
      """
    )

    # Use the raw issue map form so Context.build picks up state: "todo" as todo_dispatch?
    issue = %{id: 1, identifier: "test", state: "todo", labels: [], pr_head_ref: nil}

    assert :ok = Refresh.run(workspace, issue, nil)
    assert File.regular?(recreate_marker)
    assert File.exists?(Path.join(workspace, "rebuilt"))

    for command <- ~w(elixir mix mise) do
      assert File.regular?(Path.join([workspace, ".aiur-runtime", "build-bin", command]))
    end

    # #2697: recreation must reinstall every support piece, not only the build
    # wrappers. The agent env points PATH, GH_CONFIG_DIR and the quota path here.
    for command <- ~w(gh git aiur-github-budget) do
      assert File.regular?(Path.join([workspace, ".aiur-runtime", "bin", command]))
    end

    assert File.dir?(AgentGitHubGuard.gh_config_dir(workspace))
    assert File.dir?(Path.join([workspace, ".aiur-runtime", "github-quota"]))
    assert File.dir?(Path.join([workspace, ".aiur-runtime", "tmp"]))
    assert File.dir?(Path.join([workspace, ".claude", "skills", "aiur-agent"]))
    assert Aiur.AgentGitHubGuard.missing_workspace_support(workspace) == []

    probe_bin = Path.join(test_root, "probe-bin")
    File.mkdir_p!(probe_bin)
    File.write!(Path.join(probe_bin, "mise"), "#!/bin/sh\nprintf 'real-mise-ran\\n'\n")
    File.chmod!(Path.join(probe_bin, "mise"), 0o755)

    child = Path.join(workspace, "first-agent-build")
    File.write!(child, "#!/bin/sh\nexec mise exec -- mix compile\n")
    File.chmod!(child, 0o755)

    assert {:ok, port} =
             Adapter.start_port(
               workspace,
               Aiur.Shell.escape(child),
               fn _port -> :ok end,
               env: [{"PATH", Enum.join([probe_bin, "/usr/bin", "/bin"], ":")}]
             )

    assert_receive {^port, {:data, {:eol, "aiur_build_gate acquired" <> _details}}}, 1_000
    assert_receive {^port, {:data, {:eol, "real-mise-ran"}}}, 1_000
    assert_receive {^port, {:data, {:eol, "aiur_build_gate released" <> _details}}}, 1_000
    assert_receive {^port, {:exit_status, 0}}, 1_000
  end

  test "run/3 reconstruction restores the governed GitHub wrapper and private config before dispatch", %{
    workspace: workspace,
    test_root: test_root
  } do
    init_repo!(workspace)
    recreate_marker = Path.join(test_root, "reconstruct-once")

    fake_gh = Path.join(test_root, "system-bin/gh")
    observed = Path.join(test_root, "governed-gh-observed")
    credential_file = Path.join(test_root, "private-agent-token")
    expected_config_dir = AgentGitHubGuard.gh_config_dir(workspace)

    File.write!(credential_file, "private-fixture-token\n")
    File.mkdir_p!(Path.dirname(fake_gh))

    File.write!(fake_gh, """
    #!/bin/sh
    printf 'GH_TOKEN=%s\\nGITHUB_TOKEN=%s\\nGH_CONFIG_DIR=%s\\n' "${GH_TOKEN:-}" "${GITHUB_TOKEN:-}" "${GH_CONFIG_DIR:-}" > #{Aiur.Shell.escape(observed)}
    printf 'governed\\n'
    """)

    File.chmod!(fake_gh, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      hook_before_run: """
      if [ ! -f #{Aiur.Shell.escape(recreate_marker)} ]; then touch #{Aiur.Shell.escape(recreate_marker)}; exit 65; fi
      test -z "$(find . -mindepth 1 -maxdepth 1 -print -quit)"
      git init --quiet -b main
      git config user.email t@example.com
      git config user.name T
      touch rebuilt
      git add rebuilt
      git commit --quiet -m rebuilt
      """
    )

    issue = %{id: 1, identifier: "test", state: "todo", labels: [], pr_head_ref: nil}

    assert :ok = Refresh.run(workspace, issue, nil)
    assert File.regular?(recreate_marker)

    wrapper = Path.join(AgentGitHubGuard.bin_dir(workspace), "gh")
    assert File.regular?(wrapper)
    assert File.dir?(expected_config_dir)

    assert {"governed\n", 0} =
             System.cmd("sh", ["-c", "gh api repos/owner/repo/issues/2667"],
               cd: workspace,
               env: [
                 {"AIUR_REAL_GH", fake_gh},
                 {"AIUR_AGENT_BIN", AgentGitHubGuard.bin_dir(workspace)},
                 {"AIUR_AGENT_WORKSPACE", workspace},
                 {"AIUR_GITHUB_CREDENTIAL_FILE", credential_file},
                 {"AIUR_REPO_STATE_PATH", test_root},
                 {"AIUR_AGENT_QUOTA_STATE_PATH", Path.join(test_root, "quota")},
                 {"AIUR_GITHUB_BUDGET_ENABLED", "0"},
                 {"AIUR_GITHUB_BUDGET_ROOT", ""},
                 {"AIUR_GITHUB_BUDGET_KEY", ""},
                 {"AIUR_GITHUB_BUDGET_IDENTITY_KEY", ""},
                 {"AIUR_GITHUB_BUDGET_CONSUMER", ""},
                 {"AIUR_GITHUB_BUDGET_BROKER", "/nonexistent/aiur-github-budget"},
                 {"GITHUB_TOKEN", ""},
                 {"GH_TOKEN", ""},
                 {"GH_CONFIG_DIR", expected_config_dir},
                 {"PATH", "#{AgentGitHubGuard.bin_dir(workspace)}:#{Path.dirname(fake_gh)}:/usr/bin:/bin"}
               ],
               stderr_to_stdout: true
             )

    assert File.read!(observed) ==
             "GH_TOKEN=private-fixture-token\nGITHUB_TOKEN=\nGH_CONFIG_DIR=#{expected_config_dir}\n"
  end

  test "run/3 on a remote ready workspace installs only the governed GitHub guard", %{test_root: test_root} do
    previous_path = System.get_env("PATH")
    previous_script = System.get_env("AIUR_TEST_REMOTE_SCRIPT")
    remote_script = Path.join(test_root, "remote-guard-install.sh")
    fake_ssh = Path.join(test_root, "ssh")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("AIUR_TEST_REMOTE_SCRIPT", previous_script)
    end)

    File.write!(
      fake_ssh,
      """
      #!/bin/sh
      case "$*" in
        *"bash -s"*) cat > "$AIUR_TEST_REMOTE_SCRIPT" ;;
      esac
      exit 0
      """
    )

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", test_root <> ":" <> (previous_path || ""))
    System.put_env("AIUR_TEST_REMOTE_SCRIPT", remote_script)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: test_root)

    assert :ok =
             Refresh.run(
               "/remote/workspace",
               %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil},
               "worker-1"
             )

    script = File.read!(remote_script)
    assert script =~ ".aiur-runtime/bin"
    assert script =~ "for command_name in 'gh'"
    assert script =~ ".aiur-runtime/gh"
    refute script =~ ".claude/skills"
    refute script =~ ".codex/skills"
  end

  test "active ownership refuses stale-todo recreation without touching the workspace", %{workspace: workspace} do
    ticket = "refresh-active-#{System.unique_integer([:positive])}"
    sentinel = Path.join(workspace, "live-wip")
    File.write!(sentinel, "keep\n")
    error = {:error, {:workspace_hook_failed, "before_run", 65, ""}}
    issue_context = %{issue_id: 1, issue_identifier: ticket, issue_state: "todo", issue_labels: [], pr_head_ref: nil}

    assert {:ok, lease} = Ownership.claim(ticket)
    assert {:ok, _active_lease} = Ownership.activate(lease)

    on_exit(fn -> Ownership.release(lease) end)

    assert {:error, {:workspace_owned, {:ok, %{generation: generation, phase: :active}}}} =
             Refresh.maybe_recreate_stale_workspace(error, elem(error, 1), "exit 65", workspace, issue_context, nil)

    assert generation == lease.generation
    assert File.read!(sentinel) == "keep\n"
  end

  test "run/3 passes the established ticket branch to recreation hooks after a title edit", %{
    workspace: workspace,
    test_root: test_root
  } do
    init_repo!(workspace)
    git!(["-C", workspace, "checkout", "--quiet", "-b", "aiur/123-fix-login"])
    trace = Path.join(test_root, "branch-trace")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      hook_before_run: "printf '%s\\n' \"$AIUR_TICKET_BRANCH\" >> #{trace}; exit 65"
    )

    issue = %{
      id: 123,
      identifier: "123",
      title: "Fix login and signup",
      state: "todo",
      labels: [],
      pr_head_ref: nil
    }

    assert {:error, _} = Refresh.run(workspace, issue, nil)
    assert File.read!(trace) |> String.split("\n", trim: true) == ["aiur/123-fix-login", "aiur/123-fix-login"]
  end

  test "run/3 exit-65 on non-todo dispatch returns :ok (WIP skip)", %{workspace: workspace, test_root: test_root} do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      before_run: "exit 65"
    )

    issue_context = %{
      issue_id: 1,
      issue_identifier: "test",
      issue_state: "in_progress",
      issue_labels: [],
      pr_head_ref: nil
    }

    assert :ok = Refresh.run(workspace, issue_context, nil)
  end

  defp init_repo!(repo) do
    git!(["init", "--quiet", "-b", "main", repo])
    git!(["-C", repo, "config", "user.email", "t@example.com"])
    git!(["-C", repo, "config", "user.name", "T"])
    File.write!(Path.join(repo, "README.md"), "initial\n")
    git!(["-C", repo, "add", "."])
    git!(["-C", repo, "commit", "--quiet", "-m", "initial"])
  end

  defp git!(args) do
    {out, 0} = System.cmd("git", args, stderr_to_stdout: true)
    out
  end
end
