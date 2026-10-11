defmodule Aiur.Orchestrator.Deactivate.NoReactivationTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.OrchestratorDeactivateSupport.ErrorLinearClient

  describe "issue.commented firehose reactivation (subscriber wiring)" do
    test "does not reactivate a human-review entry on ticket.<N>.issue.commented" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-issue-commented-human-review")

      issue_id = "issue-issue-commented-hr"
      issue_identifier = "43"
      previous_memory_issues = Application.get_env(:aiur, :memory_tracker_issues)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)

        Application.put_env(:aiur, :memory_tracker_issues, [
          %Issue{
            id: issue_id,
            identifier: issue_identifier,
            state: "human-review",
            title: "Ready for human review",
            description: "",
            labels: []
          }
        ])

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
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        {:noreply, next} =
          Orchestrator.handle_info(
            {:event, %{topic: "ticket.#{issue_identifier}.issue.commented"}},
            state
          )

        entry = Map.fetch!(next.running, issue_id)
        assert get_in(entry, [:control, :status]) == :deactivated
        assert entry.pid == nil
      after
        if previous_memory_issues do
          Application.put_env(:aiur, :memory_tracker_issues, previous_memory_issues)
        else
          Application.delete_env(:aiur, :memory_tracker_issues)
        end

        File.rm_rf(test_root)
      end
    end

    test "review-pass PR comment stays human-review until successful merge marks issue done" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-review-pass-merge")

      issue_id = "560"
      issue_identifier = "560"
      previous_memory_issues = Application.get_env(:aiur, :memory_tracker_issues)
      previous_memory_recipient = Application.get_env(:aiur, :memory_tracker_recipient)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        Application.put_env(:aiur, :memory_tracker_recipient, self())
        Application.put_env(:aiur, :memory_tracker_issues, [])

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
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        {:noreply, after_comment} =
          Orchestrator.handle_info(
            {:event,
             %{
               topic: "ticket.#{issue_identifier}.issue.commented",
               author_trusted?: true,
               comment: %{body: "[codex] Review passed for commit abc123"}
             }},
            state
          )

        # handle_info/2 synchronously completes the transition decision.
        refute_received {:memory_tracker_state_update, ^issue_id, "rework"}
        assert get_in(after_comment.running[issue_id], [:control, :status]) == :deactivated

        {:noreply, after_review_comment} =
          Orchestrator.handle_info(
            {:event,
             %{
               topic: "ticket.#{issue_identifier}.pr.review_comment",
               author_trusted?: true,
               comment: %{body: "[codex] Review passed for commit abc123"}
             }},
            after_comment
          )

        # handle_info/2 synchronously completes the transition decision.
        refute_received {:memory_tracker_state_update, ^issue_id, "rework"}
        assert get_in(after_review_comment.running[issue_id], [:control, :status]) == :deactivated

        {:noreply, after_merge} =
          Orchestrator.handle_info(
            {:event,
             %{
               topic: "ticket.#{issue_identifier}.pr.merged",
               pr: %{"body" => "Closes ##{issue_identifier}"}
             }},
            after_review_comment
          )

        # The memory-tracker notification is a real downstream side effect of
        # the merge transition, but it is delivered synchronously to the test
        # process: the merge handler calls Tracker.update_issue_state, which
        # for the memory adapter sends straight to memory_tracker_recipient
        # (self()) before handle_info returns. The 100ms ExUnit default is the
        # file's own convention for this signal (every other
        # {:memory_tracker_state_update, ...} assert here uses it), so the
        # observed #1920 flake was not a timing race but the shared
        # WorkflowStore singleton being mid-restart, which made the tracker
        # adapter resolve to a non-memory kind and the notification never be
        # sent. That TOCTOU is fixed in production (WorkflowStore.force_reload
        # now absorbs a dying store), so no budget bump is needed.
        receive_barrier({:memory_tracker_state_update, ^issue_id, "done"})
        refute Map.has_key?(after_merge.running, issue_id)
        refute MapSet.member?(after_merge.claimed, issue_id)
      after
        if previous_memory_issues do
          Application.put_env(:aiur, :memory_tracker_issues, previous_memory_issues)
        else
          Application.delete_env(:aiur, :memory_tracker_issues)
        end

        if previous_memory_recipient do
          Application.put_env(:aiur, :memory_tracker_recipient, previous_memory_recipient)
        else
          Application.delete_env(:aiur, :memory_tracker_recipient)
        end

        File.rm_rf(test_root)
      end
    end

    test "does not reactivate when refreshed issue is missing" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-issue-commented-missing")

      issue_id = "issue-issue-commented-missing"
      issue_identifier = "45"
      previous_memory_issues = Application.get_env(:aiur, :memory_tracker_issues)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        Application.put_env(:aiur, :memory_tracker_issues, [])

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
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        parent = self()

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            send(
              parent,
              Orchestrator.handle_info(
                {:event, %{topic: "ticket.#{issue_identifier}.issue.commented", author_trusted?: true}},
                state
              )
            )
          end)

        receive_barrier({:noreply, next})
        entry = Map.fetch!(next.running, issue_id)
        assert get_in(entry, [:control, :status]) == :deactivated
        assert entry.pid == nil
        assert log =~ "issue_id=#{issue_id} issue_identifier=#{issue_identifier}"
        assert log =~ "reason=:missing"
      after
        if previous_memory_issues do
          Application.put_env(:aiur, :memory_tracker_issues, previous_memory_issues)
        else
          Application.delete_env(:aiur, :memory_tracker_issues)
        end

        File.rm_rf(test_root)
      end
    end

    test "does not reactivate when tracker refresh fails" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-issue-commented-refresh-error")

      issue_id = "issue-issue-commented-refresh-error"
      issue_identifier = "46"
      previous_linear_client = Application.get_env(:aiur, :linear_client_module)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "linear",
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        Application.put_env(:aiur, :linear_client_module, ErrorLinearClient)
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
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        parent = self()

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            send(
              parent,
              Orchestrator.handle_info(
                {:event, %{topic: "ticket.#{issue_identifier}.issue.commented", author_trusted?: true}},
                state
              )
            )
          end)

        receive_barrier({:noreply, next})
        entry = Map.fetch!(next.running, issue_id)
        assert get_in(entry, [:control, :status]) == :deactivated
        assert entry.pid == nil
        assert log =~ "issue_id=#{issue_id} issue_identifier=#{issue_identifier}"
        assert log =~ "reason=:tracker_down"
      after
        if previous_linear_client do
          Application.put_env(:aiur, :linear_client_module, previous_linear_client)
        else
          Application.delete_env(:aiur, :linear_client_module)
        end

        File.rm_rf(test_root)
      end
    end
  end
end
