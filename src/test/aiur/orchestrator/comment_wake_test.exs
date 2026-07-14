defmodule Aiur.Orchestrator.CommentWakeTest do
  use Aiur.TestSupport

  alias Aiur.{AgentQueue, AgentQueueStore}
  alias Aiur.Orchestrator.{CommentWake, State}

  defp base_state do
    %State{
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      codex_thrash_budget: %{},
      queue_store: nil,
      last_polled_issues: %{},
      todo_over_capacity_alert_active: false,
      agent_totals: nil,
      agent_rate_limits: nil,
      codex_totals: nil,
      codex_rate_limits: nil,
      poll_interval_ms: 60_000,
      max_concurrent_agents: nil,
      session_max_concurrent_agents: nil,
      effective_concurrent_agents: nil,
      load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: nil},
      next_poll_due_at_ms: nil,
      poll_check_in_progress: nil,
      tick_timer_ref: nil,
      tick_token: nil,
      initial_dispatch_cycle: false,
      events_etag: nil,
      events_last_id: nil,
      github_comments_since: %{},
      github_comment_issue_updated_at: %{},
      github_connectivity: %{},
      github_poll_delays: %{},
      github_command_scan_since: nil
    }
  end

  describe "trusted_comment_event?/1" do
    test "returns false for untrusted author" do
      event = %{author_trusted?: false}
      refute CommentWake.trusted_comment_event?(event)
    end

    test "returns false when author_trusted? key is missing" do
      event = %{topic: "ticket.1.issue.commented"}
      refute CommentWake.trusted_comment_event?(event)
    end

    test "returns true for trusted author (atom key)" do
      event = %{author_trusted?: true}
      assert CommentWake.trusted_comment_event?(event)
    end

    test "returns true for trusted author (string key)" do
      event = %{"author_trusted?" => true}
      assert CommentWake.trusted_comment_event?(event)
    end
  end

  describe "actionable_trusted_comment_event?/1" do
    test "ignores only a recorded agent-origin comment" do
      agent_event = %{author_trusted?: true, comment_origin: "agent", comment: %{"body" => "Fixed."}}
      human_event = %{author_trusted?: true, comment_origin: "external", comment: %{"body" => "Please rework this."}}

      assert CommentWake.trusted_comment_event?(agent_event)
      refute CommentWake.actionable_trusted_comment_event?(agent_event)
      assert CommentWake.actionable_trusted_comment_event?(human_event)
    end
  end

  describe "benign_review_pass_comment?/1" do
    test "recognizes bot review passed comment (lowercase)" do
      event = %{comment: %{"body" => "[codex] review passed"}}
      assert CommentWake.benign_review_pass_comment?(event)
    end

    test "recognizes bot review passed with mixed case" do
      event = %{comment: %{"body" => "[Codex] Review Passed now"}}
      assert CommentWake.benign_review_pass_comment?(event)
    end

    test "returns false for regular comment" do
      event = %{comment: %{"body" => "LGTM"}}
      refute CommentWake.benign_review_pass_comment?(event)
    end

    test "returns false for missing comment" do
      event = %{topic: "ticket.1.issue.commented"}
      refute CommentWake.benign_review_pass_comment?(event)
    end
  end

  describe "comment_rework_retry_delay_ms/1" do
    test "returns base delay for attempt 1" do
      assert CommentWake.comment_rework_retry_delay_ms(1) == 2_000
    end

    test "returns larger delay for attempt 2 (exponential backoff)" do
      delay1 = CommentWake.comment_rework_retry_delay_ms(1)
      delay2 = CommentWake.comment_rework_retry_delay_ms(2)
      assert delay1 == 2_000
      assert delay2 == 4_000
    end

    test "delay is 2000-based (at attempt 1 returns base delay)" do
      assert CommentWake.comment_rework_retry_delay_ms(5) == 32_000
    end
  end

  describe "comment_rework_max_attempts/0" do
    test "returns 5" do
      assert CommentWake.comment_rework_max_attempts() == 5
    end
  end

  describe "mark_pr_merged_issue_done/2" do
    test "returns state unchanged when no matching running entry exists" do
      state = base_state()
      result = CommentWake.mark_pr_merged_issue_done(state, "nonexistent-123")
      assert result == state
    end
  end

  describe "CI re-wake handoffs" do
    test "trusted feedback supersedes stale guidance before completed-runner replacement" do
      issue_id = "comment-wake-ci-rewake"
      identifier = "comment-wake-#{System.unique_integer([:positive])}"
      configure_memory_tracker([%Issue{id: issue_id, identifier: identifier, state: "ci-wait", title: "Await CI"}])

      stale_rewake = %{
        id: System.unique_integer([:positive]),
        topic: "ticket.#{identifier}.ci.rewake",
        source: :runtime,
        message: "Check CI once; if it is still pending, return to agent:ci-wait."
      }

      {queue_store, stale_item} =
        AgentQueue.coordination_event(identifier, :events_digest, %{
          summary: stale_rewake.message,
          events: [stale_rewake]
        })
        |> then(&AgentQueueStore.enqueue(AgentQueueStore.new(), &1))

      {queue_store, _delivered_stale_item} = AgentQueueStore.claim_next_deliverable(queue_store, identifier)

      entry =
        lifecycle_running_entry(issue_id, identifier)
        |> Map.put(:pid, nil)
        |> Map.put(:last_codex_event, :turn_completed)
        |> Map.put(:issue, %Issue{id: issue_id, identifier: identifier, state: "ci-wait", title: "Await CI"})

      state =
        lifecycle_state(
          running: %{issue_id => entry},
          claimed: MapSet.new([issue_id]),
          queue_store: queue_store
        )

      feedback = trusted_comment_event(identifier)

      assert {:noreply, next} = Orchestrator.handle_info({:event, feedback}, state)

      assert_receive {:memory_tracker_state_update, ^issue_id, "rework"}, 2_000
      assert AgentQueueStore.get(next.queue_store, stale_item.id).status == :superseded

      assert [%{body: %{events: [^feedback]}}] = AgentQueueStore.list_pending(next.queue_store, identifier)
    end
  end

  defp lifecycle_state(attrs) do
    struct!(
      State,
      Keyword.merge(
        [
          running: %{},
          claimed: MapSet.new(),
          retry_attempts: %{},
          max_concurrent_agents: 6,
          session_max_concurrent_agents: nil,
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
        ],
        attrs
      )
    )
  end

  defp configure_memory_tracker(issues) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["todo", "in-progress", "human-review", "rework", "merging"],
      tracker_terminal_states: ["done", "cancelled", "canceled"]
    )

    Application.put_env(:aiur, :memory_tracker_recipient, self())
    Application.put_env(:aiur, :memory_tracker_issues, issues)
  end

  defp lifecycle_running_entry(issue_id, identifier) do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: identifier,
      issue: %Issue{id: issue_id, identifier: identifier, state: "In Progress", title: nil},
      control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :working},
      session_id: "thread-#{identifier}",
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      started_at: DateTime.utc_now()
    }
  end

  defp trusted_comment_event(identifier) do
    %{
      id: System.unique_integer([:positive]),
      topic: "ticket.#{identifier}.pr.review_comment",
      source: :github,
      author_trusted?: true,
      message: "please rework",
      comment: %{"body" => "please rework"}
    }
  end
end
