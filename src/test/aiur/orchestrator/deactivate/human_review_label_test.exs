defmodule Aiur.Orchestrator.Deactivate.HumanReviewLabelTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.OrchestratorDeactivateSupport.HumanReviewGuardGitHubClient
  alias Aiur.SessionHandle

  import Aiur.OrchestratorDeactivateSupport

  describe "reconcile on agent:human-review label" do
    test "human-review state keeps the running entry, kills the task, marks :deactivated" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-deactivate")

      issue_id = "issue-deactivate-1"
      issue_identifier = "DA-1"
      workspace = Path.join(test_root, issue_identifier)
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
        :ok = SessionHandle.save(issue_identifier, %{backend: "codex", thread_id: "thread-keep"})

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

        updated_state = Reconciler.reconcile_running_issue_states([issue], state)

        # Entry survives — this is the whole point of the deactivate path.
        assert Map.has_key?(updated_state.running, issue_id)
        assert MapSet.member?(updated_state.claimed, issue_id)

        # Codex task pid was killed (mirror terminate_running_issue's teardown).
        refute Process.alive?(agent_pid)

        # Entry shape: pid cleared, control.status flipped to :deactivated.
        entry = Map.fetch!(updated_state.running, issue_id)
        assert is_nil(entry.pid)
        assert get_in(entry, [:control, :status]) == :deactivated

        # Workspace not cleaned up (deactivation is non-terminal).
        assert File.exists?(workspace)
        assert {:ok, %{thread_id: "thread-keep"}} = SessionHandle.load(issue_identifier, "codex")
      after
        restore_application_env(:log_file, previous_log_file)
        File.rm_rf(test_root)
      end
    end

    test "human-review on an already-deactivated entry is a no-op" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-deactivate-noop")

      issue_id = "issue-deactivate-2"
      issue_identifier = "DA-2"

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: nil,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "human-review", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :deactivated}
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

        updated_state = Reconciler.reconcile_running_issue_states([issue], state)

        # Same shape after the second observation — no spurious task kill,
        # no double-deactivate side effect.
        entry = Map.fetch!(updated_state.running, issue_id)
        assert is_nil(entry.pid)
        assert get_in(entry, [:control, :status]) == :deactivated
      after
        File.rm_rf(test_root)
      end
    end

    test "human-review with unverified review threads is reverted to rework instead of deactivated" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-human-review-guard")

      issue_id = "57"
      issue_identifier = "57"
      previous_github_client = Application.get_env(:aiur, :github_client_module)
      previous_guard_recipient = Application.get_env(:aiur, :human_review_guard_recipient)
      previous_ready_result = Application.get_env(:aiur, :human_review_ready_result)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "github",
          workspace_root: test_root,
          tracker_repo: "owner/repo",
          tracker_label_prefix: "agent",
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        Application.put_env(:aiur, :github_client_module, HumanReviewGuardGitHubClient)
        Application.put_env(:aiur, :human_review_guard_recipient, self())

        Application.put_env(
          :aiur,
          :human_review_ready_result,
          {:error, {:unverified_review_threads, %{count: 1, review_thread_ids: ["PRRT_missing"]}}}
        )

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

        updated_state = Reconciler.reconcile_running_issue_states([issue], state)

        receive_barrier({:human_review_verify, ^issue_id})
        receive_barrier({:human_review_update, ^issue_id, "rework"})
        assert Process.alive?(agent_pid)

        entry = Map.fetch!(updated_state.running, issue_id)
        assert entry.pid == agent_pid
        assert entry.issue.state == "rework"
        assert get_in(entry, [:control, :status]) == :working
      after
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
        restore_application_env(:github_client_module, previous_github_client)
        restore_application_env(:human_review_guard_recipient, previous_guard_recipient)
        restore_application_env(:human_review_ready_result, previous_ready_result)
        File.rm_rf(test_root)
      end
    end

    test "human-review with a transient verification error is left for a later poll" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-human-review-transient")

      issue_id = "58"
      issue_identifier = "58"
      previous_github_client = Application.get_env(:aiur, :github_client_module)
      previous_guard_recipient = Application.get_env(:aiur, :human_review_guard_recipient)
      previous_ready_result = Application.get_env(:aiur, :human_review_ready_result)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "github",
          workspace_root: test_root,
          tracker_repo: "owner/repo",
          tracker_label_prefix: "agent",
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        Application.put_env(:aiur, :github_client_module, HumanReviewGuardGitHubClient)
        Application.put_env(:aiur, :human_review_guard_recipient, self())

        Application.put_env(
          :aiur,
          :human_review_ready_result,
          {:error, {:github, :rate_limited, %{status: 429}}}
        )

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

        updated_state = Reconciler.reconcile_running_issue_states([issue], state)

        receive_barrier({:human_review_verify, ^issue_id})
        refute_received {:human_review_update, ^issue_id, "rework"}
        assert Process.alive?(agent_pid)

        entry = Map.fetch!(updated_state.running, issue_id)
        assert entry.pid == agent_pid
        assert entry.issue.state == "in-progress"
        assert get_in(entry, [:control, :status]) == :working
      after
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
        restore_application_env(:github_client_module, previous_github_client)
        restore_application_env(:human_review_guard_recipient, previous_guard_recipient)
        restore_application_env(:human_review_ready_result, previous_ready_result)
        File.rm_rf(test_root)
      end
    end

    test "human-review with transient GraphQL verification errors is left for a later poll" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-human-review-graphql-transient")

      previous_github_client = Application.get_env(:aiur, :github_client_module)
      previous_guard_recipient = Application.get_env(:aiur, :human_review_guard_recipient)
      previous_ready_result = Application.get_env(:aiur, :human_review_ready_result)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "github",
          workspace_root: test_root,
          tracker_repo: "owner/repo",
          tracker_label_prefix: "agent",
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        Application.put_env(:aiur, :github_client_module, HumanReviewGuardGitHubClient)
        Application.put_env(:aiur, :human_review_guard_recipient, self())

        transient_errors = [
          {"58", [%{"type" => "RATE_LIMITED", "message" => "secondary rate limit"}]},
          {"59", [%{"type" => "INTERNAL", "message" => "server error"}]},
          {"60", [%{"extensions" => %{"code" => "INTERNAL_SERVER_ERROR"}}]},
          {"61", [%{type: :SERVICE_UNAVAILABLE}]}
        ]

        for {issue_id, errors} <- transient_errors do
          agent_pid =
            spawn(fn ->
              receive do
                :stop -> :ok
              end
            end)

          try do
            Application.put_env(
              :aiur,
              :human_review_ready_result,
              {:error, {:github_graphql_errors, errors}}
            )

            state = human_review_running_state(issue_id, agent_pid)
            issue = human_review_issue(issue_id)

            updated_state = Reconciler.reconcile_running_issue_states([issue], state)

            receive_barrier({:human_review_verify, ^issue_id})
            refute_received {:human_review_update, ^issue_id, "rework"}
            assert Process.alive?(agent_pid)

            entry = Map.fetch!(updated_state.running, issue_id)
            assert entry.pid == agent_pid
            assert entry.issue.state == "in-progress"
            assert get_in(entry, [:control, :status]) == :working
          after
            if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
          end
        end
      after
        restore_application_env(:github_client_module, previous_github_client)
        restore_application_env(:human_review_guard_recipient, previous_guard_recipient)
        restore_application_env(:human_review_ready_result, previous_ready_result)
        File.rm_rf(test_root)
      end
    end

    test "human-review with a non-verdict GraphQL verification error is left for a later poll" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-human-review-graphql-nonverdict")

      issue_id = "62"
      previous_github_client = Application.get_env(:aiur, :github_client_module)
      previous_guard_recipient = Application.get_env(:aiur, :human_review_guard_recipient)
      previous_ready_result = Application.get_env(:aiur, :human_review_ready_result)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "github",
          workspace_root: test_root,
          tracker_repo: "owner/repo",
          tracker_label_prefix: "agent",
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        Application.put_env(:aiur, :github_client_module, HumanReviewGuardGitHubClient)
        Application.put_env(:aiur, :human_review_guard_recipient, self())

        # A FORBIDDEN threads read is an authorization/operational fault, not a
        # reviewer verdict: it says nothing about whether the reviewer's findings
        # were addressed (#2400). The ticket must rest in `human-review` and
        # re-verify on the next poll, never revert to `rework` (a state whose
        # turn has nothing to fix).
        Application.put_env(
          :aiur,
          :human_review_ready_result,
          {:error, {:github_graphql_errors, [%{"type" => "FORBIDDEN", "message" => "denied"}]}}
        )

        state = human_review_running_state(issue_id, agent_pid)
        issue = human_review_issue(issue_id)

        updated_state = Reconciler.reconcile_running_issue_states([issue], state)

        receive_barrier({:human_review_verify, ^issue_id})
        refute_received {:human_review_update, ^issue_id, "rework"}
        assert Process.alive?(agent_pid)

        entry = Map.fetch!(updated_state.running, issue_id)
        assert entry.pid == agent_pid
        assert entry.issue.state == "in-progress"
        assert get_in(entry, [:control, :status]) == :working
      after
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
        restore_application_env(:github_client_module, previous_github_client)
        restore_application_env(:human_review_guard_recipient, previous_guard_recipient)
        restore_application_env(:human_review_ready_result, previous_ready_result)
        File.rm_rf(test_root)
      end
    end
  end
end
