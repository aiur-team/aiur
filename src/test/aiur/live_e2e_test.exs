defmodule Aiur.LiveE2ETest do
  use Aiur.TestSupport

  import Aiur.LiveE2E.{LinearApi, WorkerSetup}

  alias Aiur.SSH

  @moduletag :live_e2e
  @moduletag timeout: 300_000

  @default_team_key "SYME2E"
  @result_file "LIVE_E2E_RESULT.txt"
  @live_e2e_skip_reason if(System.get_env("AIUR_RUN_LIVE_E2E") != "1",
                          do: "set AIUR_RUN_LIVE_E2E=1 to enable the real Linear/Codex end-to-end test"
                        )

  @tag skip: @live_e2e_skip_reason
  test "creates a real Linear project and issue with a local worker" do
    run_live_issue_flow!(:local)
  end

  @tag skip: @live_e2e_skip_reason
  test "creates a real Linear project and issue with an ssh worker" do
    run_live_issue_flow!(:ssh)
  end

  defp live_prompt(project_slug) do
    """
    You are running a real Aiur end-to-end test.

    The current working directory is the workspace root.

    Step 1:
    Create a file named #{@result_file} in the current working directory by running exactly:

    ```sh
    cat > #{@result_file} <<'EOF'
    identifier={{ issue.identifier }}
    project_slug=#{project_slug}
    EOF
    ```

    Then verify it by running:

    ```sh
    cat #{@result_file}
    ```

    The file content must be exactly:
    identifier={{ issue.identifier }}
    project_slug=#{project_slug}

    Step 2:
    You must use the `linear_graphql` tool to query the current issue by `{{ issue.id }}` and read:
    - existing comments
    - team workflow states

    A turn that only creates the file is incomplete. Do not stop after Step 1.

    If the exact comment body below is not already present, post exactly one comment on the current issue with this exact body:
    #{expected_comment("{{ issue.identifier }}", project_slug)}

    Use these exact GraphQL operations:

    ```graphql
    query IssueContext($id: String!) {
      issue(id: $id) {
        comments(first: 20) {
          nodes {
            body
          }
        }
        team {
          states(first: 50) {
            nodes {
              id
              name
              type
            }
          }
        }
      }
    }
    ```

    ```graphql
    mutation AddComment($issueId: String!, $body: String!) {
      commentCreate(input: {issueId: $issueId, body: $body}) {
        success
      }
    }
    ```

    Step 3:
    Use the same issue-context query result to choose a workflow state whose `type` is `completed`.
    Then move the current issue to that state with this exact mutation:

    ```graphql
    mutation CompleteIssue($id: String!, $stateId: String!) {
      issueUpdate(id: $id, input: {stateId: $stateId}) {
        success
      }
    }
    ```

    Step 4:
    Verify all outcomes with one final `linear_graphql` query against `{{ issue.id }}`:
    - the exact comment body is present
    - the issue state type is `completed`

    Do not ask for approval.
    Stop only after all three conditions are true:
    1. the file exists with the exact contents above
    2. the Linear comment exists with the exact body above
    3. the Linear issue is in a completed terminal state
    """
  end

  defp expected_result(issue_identifier, project_slug) do
    "identifier=#{issue_identifier}\nproject_slug=#{project_slug}\n"
  end

  defp expected_comment(issue_identifier, project_slug) do
    "Aiur live e2e comment\nidentifier=#{issue_identifier}\nproject_slug=#{project_slug}"
  end

  defp receive_runtime_info!(issue_id) do
    receive do
      {:worker_runtime_info, ^issue_id, %{workspace_path: workspace_path} = runtime_info}
      when is_binary(workspace_path) ->
        runtime_info

      {:codex_worker_update, ^issue_id, _message} ->
        receive_runtime_info!(issue_id)
    after
      5_000 ->
        flunk("timed out waiting for worker runtime info for #{inspect(issue_id)}")
    end
  end

  defp read_worker_result!(%{worker_host: nil, workspace_path: workspace_path}, result_file)
       when is_binary(workspace_path) and is_binary(result_file) do
    File.read!(Path.join(workspace_path, result_file))
  end

  defp read_worker_result!(%{worker_host: worker_host, workspace_path: workspace_path}, result_file)
       when is_binary(worker_host) and is_binary(workspace_path) and is_binary(result_file) do
    remote_result_path = Path.join(workspace_path, result_file)

    case SSH.run(worker_host, "cat #{shell_escape(remote_result_path)}", stderr_to_stdout: true) do
      {:ok, {output, 0}} ->
        output

      {:ok, {output, status}} ->
        flunk("failed to read remote result from #{worker_host}:#{remote_result_path} (status #{status}): #{inspect(output)}")

      {:error, reason} ->
        flunk("failed to read remote result from #{worker_host}:#{remote_result_path}: #{inspect(reason)}")
    end
  end

  defp run_live_issue_flow!(backend) when backend in [:local, :ssh] do
    run_id = "aiur-live-e2e-#{backend}-#{System.unique_integer([:positive])}"
    test_root = Aiur.TestSupport.tmp_root!("aiur-live-e2e-#{backend}")
    workflow_root = Path.join(test_root, "workflow")
    workflow_file = Path.join(workflow_root, "config.yaml")
    worker_setup = live_worker_setup!(backend, run_id, test_root)
    team_key = System.get_env("AIUR_LIVE_LINEAR_TEAM_KEY") || @default_team_key
    original_workflow_path = Workflow.workflow_file_path()
    orchestrator_pid = Process.whereis(Aiur.Orchestrator)

    File.mkdir_p!(workflow_root)

    try do
      if is_pid(orchestrator_pid) do
        assert :ok = Supervisor.terminate_child(Aiur.Supervisor, Aiur.Orchestrator)
      end

      Workflow.set_workflow_file_path(workflow_file)

      write_workflow_file!(workflow_file,
        tracker_api_token: "$LINEAR_API_KEY",
        tracker_project_slug: "bootstrap",
        workspace_root: worker_setup.workspace_root,
        worker_ssh_hosts: worker_setup.ssh_worker_hosts,
        codex_command: worker_setup.codex_command,
        codex_approval_policy: "never",
        observability_enabled: false
      )

      team = fetch_team!(team_key)
      active_state = active_state!(team)
      completed_project_status = completed_project_status!()
      terminal_states = terminal_state_names(team)

      project =
        create_project!(
          team["id"],
          "Aiur Live E2E #{backend} #{System.unique_integer([:positive])}"
        )

      issue =
        create_issue!(
          team["id"],
          project["id"],
          active_state["id"],
          "Aiur live e2e #{backend} issue for #{project["name"]}"
        )

      write_workflow_file!(workflow_file,
        tracker_api_token: "$LINEAR_API_KEY",
        tracker_project_slug: project["slugId"],
        tracker_active_states: active_state_names(team),
        tracker_terminal_states: terminal_states,
        workspace_root: worker_setup.workspace_root,
        worker_ssh_hosts: worker_setup.ssh_worker_hosts,
        codex_command: worker_setup.codex_command,
        codex_approval_policy: "never",
        codex_turn_timeout_ms: 600_000,
        codex_stall_timeout_ms: 600_000,
        observability_enabled: false,
        prompt: live_prompt(project["slugId"])
      )

      assert :ok = AgentRunner.run(issue, self(), max_turns: 3)

      runtime_info = receive_runtime_info!(issue.id)

      assert read_worker_result!(runtime_info, @result_file) ==
               expected_result(issue.identifier, project["slugId"])

      issue_snapshot = fetch_issue_details!(issue.id)
      assert issue_completed?(issue_snapshot)
      assert issue_has_comment?(issue_snapshot, expected_comment(issue.identifier, project["slugId"]))

      assert :ok = complete_project(project["id"], completed_project_status["id"])
    after
      restart_orchestrator_if_needed()
      cleanup_live_worker_setup(worker_setup)
      Workflow.set_workflow_file_path(original_workflow_path)
      File.rm_rf(test_root)
    end
  end
end
