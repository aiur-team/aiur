defmodule Aiur.Core.OrchestratorReconciliationTest do
  use Aiur.TestSupport
  alias Aiur.Orchestrator.Reconciler

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-nonactive-reconcile")

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Reconciler.reconcile_running_issue_states([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "unexplained error issue state preserves a running agent" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-error-reconcile")

    issue_id = "issue-error"
    issue_identifier = "MT-ERR"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "error",
        title: "Unexpected error label",
        description: "",
        labels: []
      }

      log =
        capture_log(fn ->
          send(self(), {:updated_state, Reconciler.reconcile_running_issue_states([issue], state)})
        end)

      assert_receive {:updated_state, updated_state}, 1000

      assert Map.has_key?(updated_state.running, issue_id)
      assert MapSet.member?(updated_state.claimed, issue_id)
      assert Process.alive?(agent_pid)
      assert File.exists?(workspace)
      assert Map.fetch!(updated_state.running, issue_id).issue.state == "error"

      assert log =~ "Issue reported error state while agent is still active"
      assert log =~ "issue_id=#{issue_id}"
      assert log =~ "issue_identifier=#{issue_identifier}"
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops running agent and cleans workspace" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-terminal-reconcile")

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    # Linear default config namespaces workspaces under <root>/<project_slug>/.
    workspace = Path.join([test_root, "project", issue_identifier])

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Reconciler.reconcile_running_issue_states([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      # The save and delete of a closed ticket's workspace run in a task (#2743).
      assert_receive {:workspace_cleanup_finished, ^issue_identifier, :ok}, 10_000
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end
end
