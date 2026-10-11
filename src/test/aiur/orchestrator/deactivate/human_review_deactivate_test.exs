defmodule Aiur.Orchestrator.Deactivate.HumanReviewDeactivateTest do
  use Aiur.TestSupport

  alias Aiur.AgentPubSub
  alias Aiur.Issue
  alias Aiur.Opencode.ActiveTurns
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.SessionHandle

  import Aiur.OrchestratorDeactivateSupport

  describe "reconcile on agent:human-review label" do
    test "terminate (terminal label) also broadcasts aiur_turn_done for every active chat stream" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-terminate-stream")

      issue_id = "issue-terminate-stream"
      issue_identifier = "TS-1"
      turn_a = "t-term-a"
      turn_b = "t-term-b"

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)

        # Same two-stream prewarm-race shape as the deactivate test.
        ActiveTurns.put(issue_identifier, turn_a)
        ActiveTurns.put(issue_identifier, turn_b)

        :ok = AgentPubSub.subscribe_agent(issue_identifier)

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
              issue: %Issue{id: issue_id, state: "in-progress", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :working}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }

        # Terminal label → terminate_running_issue with cleanup_workspace=true
        issue = %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "done",
          title: "merged",
          description: "",
          labels: []
        }

        _ = Reconciler.reconcile_running_issue_states([issue], state)

        receive_barrier({:aiur_turn_done, ^issue_identifier, ^turn_a, :terminal})
        receive_barrier({:aiur_turn_done, ^issue_identifier, ^turn_b, :terminal})

        assert {:closed, :terminal} = ActiveTurns.lookup(issue_identifier, turn_a)
        assert {:closed, :terminal} = ActiveTurns.lookup(issue_identifier, turn_b)
      after
        File.rm_rf(test_root)
      end
    end

    test "deactivate broadcasts aiur_turn_done for every active chat-completion stream" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-deactivate-stream")

      issue_id = "issue-deactivate-stream"
      issue_identifier = "DS-1"
      turn_a = "t-stream-a"
      turn_b = "t-stream-b"

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)

        # Simulate two pre-warmed chat completion SSE streams for the
        # same identifier (the real-world cause of the duplicate
        # "No turn activity" messages).
        ActiveTurns.put(issue_identifier, turn_a)
        ActiveTurns.put(issue_identifier, turn_b)

        :ok = AgentPubSub.subscribe_agent(issue_identifier)

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
              issue: %Issue{id: issue_id, state: "in-progress", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :working}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }

        issue = %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "human-review",
          title: "PR up for review",
          description: "",
          labels: []
        }

        _ = Reconciler.reconcile_running_issue_states([issue], state)

        # Both streams receive the close broadcast.
        receive_barrier({:aiur_turn_done, ^issue_identifier, ^turn_a, :deactivated})
        receive_barrier({:aiur_turn_done, ^issue_identifier, ^turn_b, :deactivated})

        # The ActiveTurns entries are marked closed so any late SSE
        # subscribe finalizes with the same reason instead of waiting
        # on the broadcast it missed.
        assert {:closed, :deactivated} = ActiveTurns.lookup(issue_identifier, turn_a)
        assert {:closed, :deactivated} = ActiveTurns.lookup(issue_identifier, turn_b)
      after
        File.rm_rf(test_root)
      end
    end

    test "terminal label still terminates and cleans workspace (not intercepted by deactivate)" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-deactivate-terminal")

      issue_id = "issue-deactivate-3"
      issue_identifier = "DA-3"
      # Linear default config namespaces workspaces under <root>/<project_slug>/.
      workspace = Path.join([test_root, "project", issue_identifier])
      previous_log_file = Application.get_env(:aiur, :log_file)

      try do
        Application.put_env(:aiur, :log_file, Path.join([test_root, "log", "agent.md"]))

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        File.mkdir_p!(workspace)
        :ok = SessionHandle.save(issue_identifier, %{backend: "codex", thread_id: "thread-clear"})

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
              issue: %Issue{id: issue_id, state: "in-progress", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :working}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }

        # Terminal state — the deactivate branch must NOT intercept.
        issue = %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "done",
          title: "Closed",
          description: "",
          labels: []
        }

        updated_state = Reconciler.reconcile_running_issue_states([issue], state)

        refute Map.has_key?(updated_state.running, issue_id)
        refute MapSet.member?(updated_state.claimed, issue_id)
        refute Process.alive?(agent_pid)
        # The save and delete of a closed ticket's workspace run in a task (#2743).
        assert_receive {:workspace_cleanup_finished, ^issue_identifier, :ok}, 10_000
        refute File.exists?(workspace)
        assert :none == SessionHandle.load(issue_identifier, "codex")
      after
        restore_application_env(:log_file, previous_log_file)
        File.rm_rf(test_root)
      end
    end
  end
end
