defmodule Aiur.Workspace.HooksTest do
  use Aiur.TestSupport

  alias Aiur.Workflow
  alias Aiur.Workspace.Hooks

  setup do
    test_root = Path.join(System.tmp_dir!(), "hooks_test_#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "ws")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(test_root) end)
    {:ok, workspace: workspace, test_root: test_root}
  end

  test "run_after_create/4 with created? true runs after_create hook", %{workspace: workspace, test_root: test_root} do
    sentinel = Path.join(workspace, "hook-ran")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      hook_after_create: "touch hook-ran"
    )

    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}
    assert :ok = Hooks.run_after_create(workspace, issue_context, true, nil)
    assert File.exists?(sentinel)
  end

  test "run_after_create/4 stages logs-only reconstruction and preserves the prior event stream", %{
    workspace: workspace,
    test_root: test_root
  } do
    log_path = Path.join([workspace, "logs", "agent.ndjson"])
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, "{\"event\":\"alert\"}\n")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      hook_after_create: "printf rebuilt > README.md"
    )

    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}
    assert :ok = Hooks.run_after_create(workspace, issue_context, true, nil)

    assert File.read!(Path.join(workspace, "README.md")) == "rebuilt"
    assert File.read!(log_path) == "{\"event\":\"alert\"}\n"
  end

  test "run_after_create/4 with created? :materialized returns :ok and hook does NOT run", %{workspace: workspace, test_root: test_root} do
    sentinel = Path.join(workspace, "hook-ran-materialized")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      hook_after_create: "touch #{sentinel}"
    )

    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}
    assert :ok = Hooks.run_after_create(workspace, issue_context, :materialized, nil)
    refute File.exists?(sentinel)
  end

  test "run_after_run/3 with a failing after_run hook returns :ok (failure ignored)", %{workspace: workspace, test_root: test_root} do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      hook_after_run: "exit 1"
    )

    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}
    assert :ok = Hooks.run_after_run(workspace, issue_context, nil)
  end

  test "run_github_preflight/3 with preflight disabled returns :ok", %{workspace: workspace} do
    prev = Application.get_env(:aiur, :workspace_github_preflight_enabled)
    Application.put_env(:aiur, :workspace_github_preflight_enabled, false)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:aiur, :workspace_github_preflight_enabled)
        v -> Application.put_env(:aiur, :workspace_github_preflight_enabled, v)
      end
    end)

    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}
    assert :ok = Hooks.run_github_preflight(workspace, issue_context, nil)
  end

  test "run_hook/5 local applies env scrub (RELEASE_NODE stripped from hook env)", %{workspace: workspace} do
    prev = System.get_env("RELEASE_NODE")
    System.put_env("RELEASE_NODE", "hooks-test")

    on_exit(fn ->
      case prev do
        nil -> System.delete_env("RELEASE_NODE")
        v -> System.put_env("RELEASE_NODE", v)
      end
    end)

    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}
    # If RELEASE_NODE is scrubbed, `test -z "$RELEASE_NODE"` exits 0 (:ok)
    assert :ok = Hooks.run_hook("test -z \"$RELEASE_NODE\"", workspace, issue_context, "before_run", nil)
  end

  test "run_hook/5 passes the generated ticket branch to local hooks", %{workspace: workspace} do
    issue_context = %{
      issue_id: 1,
      issue_identifier: "123",
      issue_state: nil,
      issue_labels: [],
      pr_head_ref: nil,
      branch_name: "aiur/123-add-new-test-cases"
    }

    assert :ok =
             Hooks.run_hook(
               ~s(test "$AIUR_TICKET_BRANCH" = "aiur/123-add-new-test-cases"),
               workspace,
               issue_context,
               "after_create",
               nil
             )
  end

  test "remote hook command exports the generated ticket branch", %{workspace: workspace} do
    issue_context = %{
      issue_id: 1,
      issue_identifier: "123",
      issue_state: nil,
      issue_labels: [],
      pr_head_ref: nil,
      branch_name: "aiur/123-add-new-test-cases"
    }

    command = Hooks.remote_hook_command("git checkout \"$AIUR_TICKET_BRANCH\"", workspace, issue_context)

    assert command =~ "export AIUR_TICKET_BRANCH='aiur/123-add-new-test-cases';"
    assert command =~ "cd '#{workspace}' && git checkout \"$AIUR_TICKET_BRANCH\""
  end
end
