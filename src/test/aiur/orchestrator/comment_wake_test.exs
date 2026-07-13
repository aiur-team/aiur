defmodule Aiur.Orchestrator.CommentWakeTest do
  use ExUnit.Case, async: true

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
end
