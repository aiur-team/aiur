defmodule Aiur.Orchestrator.Deactivate.CommentReactivationTest do
  use Aiur.TestSupport

  alias Aiur.AgentQueueStore
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.EventTopics

  describe "PR review-comment firehose reactivation (subscriber wiring)" do
    test "topic parser extracts the issue number from a valid topic" do
      # Helper covers the regex shape used by the orchestrator's
      # handle_info({:event, ...}) clause. Anchors guard against
      # accidental match drift if other ticket subtopics are added.
      assert {:ok, "140"} =
               EventTopics.parse_pr_review_comment_topic("ticket.140.pr.review_comment")
    end

    test "topic parser rejects unrelated topics" do
      for unrelated <- [
            "ticket.140.issue.commented",
            "ticket.140.pr.opened",
            "ticket.140.agent.progress",
            "system.repo.branch.push"
          ] do
        assert :nomatch = EventTopics.parse_pr_review_comment_topic(unrelated)
      end
    end
  end

  describe "issue.commented firehose reactivation (subscriber wiring)" do
    test "topic parser extracts the ticket number from a valid topic" do
      assert {:ok, "7"} =
               EventTopics.parse_issue_commented_topic("ticket.7.issue.commented")
    end

    test "topic parser rejects unrelated topics" do
      for unrelated <- [
            "ticket.7.pr.review_comment",
            "ticket.7.issue.comment",
            "ticket.7.issue.commented.extra",
            "ticket.7.pr.opened",
            "system.repo.branch.push"
          ] do
        assert :nomatch = EventTopics.parse_issue_commented_topic(unrelated)
      end
    end

    test "reactivates a :deactivated entry on ticket.<N>.issue.commented when refreshed state is active" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-issue-commented")

      issue_id = "issue-issue-commented-1"
      # The firehose resolves PR-conversation comments back to the ticket
      # id before publishing, so the topic number is the agent identifier.
      issue_identifier = "7"
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

        Application.put_env(:aiur, :memory_tracker_issues, [
          %Issue{
            id: issue_id,
            identifier: issue_identifier,
            state: "rework",
            title: "Rework requested",
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

        event = %{
          id: 7001,
          topic: "ticket.#{issue_identifier}.issue.commented",
          author_trusted?: true,
          comment: %{body: "Please fix the handoff."}
        }

        {:noreply, next} = Orchestrator.handle_info({:event, event}, state)

        receive_barrier({:memory_tracker_state_update, ^issue_id, "rework"})

        entry = Map.fetch!(next.running, issue_id)
        assert entry.issue.state == "rework"
        refute get_in(entry, [:control, :status]) == :deactivated

        # The durable subscription path calls this queue boundary independently
        # of the orchestrator's rework transition. Once the deactivated entry
        # is restarted, its first turn can claim the same feedback digest.
        assert {:reply, :ok, delivered} =
                 Orchestrator.handle_call({:enqueue_event_digest, issue_identifier, event}, self(), next)

        assert [
                 %{
                   event_type: :events_digest,
                   body: %{events: [^event]}
                 }
               ] = AgentQueueStore.list_pending(delivered.queue_store, issue_identifier)
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

    test "reactivates a :deactivated entry on ticket.<N>.pr.review_comment when refreshed state is active" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-pr-review-comment")

      issue_id = "issue-pr-review-comment-1"
      issue_identifier = "44"
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

        Application.put_env(:aiur, :memory_tracker_issues, [
          %Issue{
            id: issue_id,
            identifier: issue_identifier,
            state: "rework",
            title: "Review comment requested rework",
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
            {:event, %{topic: "ticket.#{issue_identifier}.pr.review_comment", author_trusted?: true}},
            state
          )

        receive_barrier({:memory_tracker_state_update, ^issue_id, "rework"})

        entry = Map.fetch!(next.running, issue_id)
        assert entry.issue.state == "rework"
        refute get_in(entry, [:control, :status]) == :deactivated
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

    # #2601: the rework turn finished, the ticket kept its `agent:rework`
    # label, and its provider was torn down to `:deactivated`. A trusted PR
    # comment then arrives with every review thread already resolved, so
    # `ReworkGate` correctly refuses the *label write* — the label is already
    # right. Refusing the wake along with it is what forced an Executor to send
    # `aiurdev message` by hand. No `rework` write happens on this path, so
    # #2422's loop stays closed.
    # #2601's headline timeline, from the live Archon reproduction on
    # 2026-09-10: PR #178's provider was deactivated with green CI, polling had
    # already reapplied `agent:rework` from the sticky aggregate verdict, and a
    # NEW trusted CHANGES_REQUESTED review then landed on a newer head. The
    # issue stayed `agent:rework` and the provider stayed deactivated until an
    # Executor sent `aiurdev message` by hand.
    #
    # The review is body-only, so it opens no review thread and the
    # unresolved-thread read reports nothing — #2473's `blocking_review_submission?`
    # signal is what carries it through the gate.
    #
    # This is CHARACTERIZATION, not a guard: it hands the event straight to the
    # orchestrator, so it passes on the base commit too. That is the point of
    # the bug — once the event exists, the wake already worked; what was missing
    # was the event, because `/reviews` was never read for a `rework` ticket.
    # The guard for that lives poll-side in `target_selection_test` and
    # `comment_polling_test`, both of which fail without the fix. This test
    # exists so a future change to #2473's delivery path cannot silently break
    # the half that #2601 depends on. The "published exactly once" half is the
    # publisher's durable `{:pr_review, …}` identity, pinned in
    # `test/aiur/events/webhook_poll_reconciliation_test.exs`.
    test "wakes a :deactivated agent:rework entry on a new CHANGES_REQUESTED review on a later head" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-rework-second-review")

      issue_id = "issue-rework-second-review"
      issue_identifier = "164"
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

        Application.put_env(:aiur, :memory_tracker_issues, [
          %Issue{
            id: issue_id,
            identifier: issue_identifier,
            state: "rework",
            title: "Rework finished, reviewer came back",
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
              issue: %Issue{id: issue_id, state: "rework", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :deactivated}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        # The head the rework turn pushed, and a review submitted against it
        # afterwards — so `ReviewFreshness` reads it as live, not stale.
        new_head = "442b4b5f4801a3b27cfec27fcfbb5747be8a579d"

        event = %{
          topic: "ticket.#{issue_identifier}.pr.review_comment",
          author_trusted?: true,
          comment: %{
            "id" => 9_601,
            "state" => "CHANGES_REQUESTED",
            "body" => "Still not right — please rework the wake path.",
            "commit_id" => new_head,
            "submitted_at" => "2026-09-10T02:01:17Z"
          },
          # The aggregate verdict is unchanged: it was already CHANGES_REQUESTED
          # from the earlier head. Only the review's own identity is new.
          pull_request: %{
            "review_decision" => "CHANGES_REQUESTED",
            "head_committed_at" => "2026-09-10T01:20:00Z"
          },
          open_pr_fetcher: fn _key -> {:ok, %{"number" => 178, "head" => %{"sha" => new_head}}} end,
          # Body-only: the review opens no inline thread.
          unresolved_threads_fetcher: fn _pr -> {:ok, []} end
        }

        {:noreply, next} = Orchestrator.handle_info({:event, event}, state)

        entry = Map.fetch!(next.running, issue_id)
        refute get_in(entry, [:control, :status]) == :deactivated
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
  end
end
