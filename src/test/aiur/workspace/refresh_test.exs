defmodule Aiur.Workspace.RefreshTest do
  use Aiur.TestSupport

  alias Aiur.{AgentEnvironment, Workflow}
  alias Aiur.Workspace.{Ownership, Refresh}

  setup do
    test_root = Path.join(System.tmp_dir!(), "refresh_test_#{System.unique_integer([:positive])}")
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

  test "run/3 exit-65 recreation restores permanent build wrappers before dispatch", %{
    workspace: workspace,
    test_root: test_root
  } do
    init_repo!(workspace)
    sentinel = Path.join(workspace, "leftover-sentinel")
    File.write!(sentinel, "leftover")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      max_concurrent_builds: 1,
      build_start_stagger_seconds: 0,
      min_free_memory_mb: nil,
      hook_before_run: """
      if [ -f leftover-sentinel ]; then exit 65; fi
      test -z "$(find . -mindepth 1 -maxdepth 1 -print -quit)"
      git init --quiet -b main
      git config user.email t@example.com
      git config user.name T
      touch rebuilt
      git add rebuilt
      git commit --quiet -m rebuilt
      """
    )

    # Use the raw issue map form so Context.build picks up state: "todo" as todo_dispatch?
    issue = %{id: 1, identifier: "test", state: "todo", labels: [], pr_head_ref: nil}

    assert :ok = Refresh.run(workspace, issue, nil)
    refute File.exists?(sentinel)
    assert File.exists?(Path.join(workspace, "rebuilt"))

    for command <- ~w(elixir mix mise) do
      assert File.regular?(Path.join([workspace, ".aiur-runtime", "build-bin", command]))
    end

    probe_bin = Path.join(test_root, "probe-bin")
    File.mkdir_p!(probe_bin)
    File.write!(Path.join(probe_bin, "mise"), "#!/bin/sh\nprintf 'real-mise-ran\\n'\n")
    File.chmod!(Path.join(probe_bin, "mise"), 0o755)

    child = Path.join(workspace, "first-agent-build")
    File.write!(child, "#!/bin/sh\nexec mise exec -- mix compile\n")
    File.chmod!(child, 0o755)

    env =
      [{"PATH", Enum.join([probe_bin, "/usr/bin", "/bin"], ":")}] ++
        Enum.flat_map(AgentEnvironment.workspace_env(workspace), fn
          {name, value} when is_list(value) -> [{to_string(name), to_string(value)}]
          _unset -> []
        end)

    command = AgentEnvironment.scrub_shell_command(Aiur.Shell.escape(child))
    assert {output, 0} = System.cmd("bash", ["-lc", command], env: env, stderr_to_stdout: true)
    assert output =~ "aiur_build_gate acquired"
    assert output =~ "real-mise-ran"
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

  test "run/3 preserves an established ticket branch when recreation follows a title edit", %{
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
    assert File.read!(trace) == "aiur/123-fix-login\naiur/123-fix-login\n"
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
