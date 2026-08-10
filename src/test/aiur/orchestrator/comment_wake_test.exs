defmodule Aiur.Orchestrator.CommentWakeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Aiur.{Issue, TrackerIdentity}
  alias Aiur.Orchestrator.{CommentWake, State}

  defp base_state do
    %State{
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
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

  # #1756: a CHANGES_REQUESTED review whose findings were addressed keeps
  # reading CHANGES_REQUESTED forever, so routing on it deadlocks the ticket in
  # `agent:rework`. The fixture is the real shape — the review predates the head
  # commit that fixed it. A skipped transition never touches the tracker, so
  # these assert both the reason and that `Tracker.update_issue_state` is not
  # reached (an unset tracker would fail loudly otherwise).
  describe "maybe_transition_idle_issue_to_rework/5 review-freshness gate" do
    @head_committed_at "2026-08-10T04:29:00Z"
    @stale_submitted_at "2026-08-08T21:15:00Z"

    defp stale_review_event(pull_request) do
      %{
        author_trusted?: true,
        comment: %{"state" => "CHANGES_REQUESTED", "body" => "please fix", "submitted_at" => @stale_submitted_at},
        pull_request: pull_request
      }
    end

    test "does not route a ticket whose CHANGES_REQUESTED review predates the head commit" do
      state = base_state()

      event =
        stale_review_event(%{"review_decision" => "CHANGES_REQUESTED", "head_committed_at" => @head_committed_at})

      log =
        capture_log(fn ->
          assert CommentWake.maybe_transition_idle_issue_to_rework(state, "1583", :pr_review, event, 1) == state
        end)

      assert log =~ "ignored for idle issue"
      assert log =~ ":stale_review"
    end

    test "does not route a ticket whose pull request is APPROVED" do
      state = base_state()

      event =
        %{
          author_trusted?: true,
          comment: %{"body" => "nice work", "submitted_at" => "2026-08-10T06:00:00Z"},
          pull_request: %{"review_decision" => "APPROVED", "head_committed_at" => @head_committed_at}
        }

      log =
        capture_log(fn ->
          assert CommentWake.maybe_transition_idle_issue_to_rework(state, "1747", :pr_comment, event, 1) == state
        end)

      assert log =~ "ignored for idle issue"
      assert log =~ ":approved_pull_request"
    end

    test "still routes a review submitted against the current head" do
      # Guards the gate against over-skipping: a live CHANGES_REQUESTED review
      # must reach the tracker update rather than be silently swallowed.
      state = base_state()

      event =
        %{
          author_trusted?: true,
          comment: %{"state" => "CHANGES_REQUESTED", "body" => "please fix", "submitted_at" => "2026-08-10T05:00:00Z"},
          pull_request: %{"review_decision" => "CHANGES_REQUESTED", "head_committed_at" => @head_committed_at}
        }

      log =
        capture_log(fn ->
          CommentWake.maybe_transition_idle_issue_to_rework(state, "1583", :pr_review, event, 1)
        end)

      refute log =~ "ignored for idle issue"
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

    test "records completed membership before terminating a merged running issue" do
      issue = %Issue{
        id: "issue-pr-merged",
        identifier: "42",
        state: "in-progress",
        tracker_identity: tracker_identity("42")
      }

      state = %{
        base_state()
        | running: %{
            issue.id => %{pid: nil, ref: nil, identifier: issue.identifier, issue: issue}
          },
          claimed: MapSet.new([issue.id])
      }

      parent = self()
      identity = issue.tracker_identity

      result =
        CommentWake.mark_pr_merged_issue_done(state, issue.identifier,
          update_issue_state_fun: fn _identifier, "done" -> :ok end,
          clear_session_handle_fun: fn _identifier -> :ok end,
          observe_membership_fun: fn identity, lifecycle ->
            send(parent, {:membership_recorded, identity, lifecycle})
            :ok
          end,
          set_terminal_verification_pending_fun: fn _identity, _pending? -> :ok end,
          terminate_running_issue_fun: fn current_state, issue_id, true ->
            assert_receive {:membership_recorded, ^identity, :completed}

            %{
              current_state
              | running: Map.delete(current_state.running, issue_id),
                claimed: MapSet.new()
            }
          end,
          merger_allowed_fun: fn _login -> true end
        )

      refute Map.has_key?(result.running, issue.id)
      refute MapSet.member?(result.claimed, issue.id)
    end

    test "does not raise alert when merged_by_login is allowlisted" do
      state = base_state()
      parent = self()

      CommentWake.mark_pr_merged_issue_done(state, "nonexistent-123",
        merged_by_login: "its-everdred",
        update_issue_state_fun: fn _id, "done" -> :ok end,
        merger_allowed_fun: fn login ->
          send(parent, {:checked_allowlist, login})
          true
        end,
        emit_alert_fun: fn _name, _opts ->
          send(parent, :unexpected_alert)
          :ok
        end
      )

      assert_receive {:checked_allowlist, "its-everdred"}
      refute_receive :unexpected_alert
    end

    test "emits unauthorized-merger alert when merged_by_login is not allowlisted" do
      state = base_state()
      parent = self()

      CommentWake.mark_pr_merged_issue_done(state, "nonexistent-123",
        merged_by_login: "unknown-bot",
        update_issue_state_fun: fn _id, "done" -> :ok end,
        merger_allowed_fun: fn login ->
          send(parent, {:checked_allowlist, login})
          false
        end,
        emit_alert_fun: fn name, opts ->
          send(parent, {:alert_emitted, name, opts})
          :ok
        end
      )

      assert_receive {:checked_allowlist, "unknown-bot"}
      assert_receive {:alert_emitted, "ticket.nonexistent-123.merge.unauthorized_merger", opts}
      assert Keyword.get(opts, :needs_attention) == true
      assert Keyword.get(opts, :severity) == "critical"
      assert Keyword.get(opts, :issue) == "nonexistent-123"
      assert Keyword.get(opts, :reason) =~ "unknown-bot"
    end

    test "emits unauthorized-merger alert when merged_by_login is nil" do
      state = base_state()
      parent = self()

      CommentWake.mark_pr_merged_issue_done(state, "nonexistent-123",
        merged_by_login: nil,
        update_issue_state_fun: fn _id, "done" -> :ok end,
        merger_allowed_fun: fn login ->
          send(parent, {:checked_allowlist, login})
          false
        end,
        emit_alert_fun: fn name, opts ->
          send(parent, {:alert_emitted, name, opts})
          :ok
        end
      )

      assert_receive {:checked_allowlist, nil}
      assert_receive {:alert_emitted, "ticket.nonexistent-123.merge.unauthorized_merger", opts}
      assert Keyword.get(opts, :needs_attention) == true
    end

    test "still emits unauthorized-merger alert when tracker update fails" do
      state = base_state()
      parent = self()

      result =
        CommentWake.mark_pr_merged_issue_done(state, "nonexistent-123",
          merged_by_login: "unknown-bot",
          update_issue_state_fun: fn _id, "done" -> {:error, :unavailable} end,
          merger_allowed_fun: fn _login -> false end,
          emit_alert_fun: fn name, opts ->
            send(parent, {:alert_emitted, name, opts})
            :ok
          end
        )

      assert_receive {:alert_emitted, "ticket.nonexistent-123.merge.unauthorized_merger", opts}
      assert Keyword.get(opts, :needs_attention) == true
      assert Keyword.get(opts, :severity) == "critical"
      assert result == state
    end

    test "default emitter supplies an explicit system alert message" do
      state = base_state()

      log =
        capture_log(fn ->
          assert CommentWake.mark_pr_merged_issue_done(state, "nonexistent-123",
                   merged_by_login: "unknown-bot",
                   update_issue_state_fun: fn _id, "done" -> :ok end,
                   merger_allowed_fun: fn _login -> false end
                 ) == state
        end)

      assert log =~
               "[alert] (#nonexistent-123) ticket.nonexistent-123.merge.unauthorized_merger"

      assert log =~ "Unauthorized PR merger \"unknown-bot\" detected for ticket nonexistent-123."
    end

    test "emits alert and still terminates running issue when merger is not allowlisted" do
      issue = %Issue{
        id: "issue-unauthorized-merge",
        identifier: "99",
        state: "in-progress",
        tracker_identity: tracker_identity("99")
      }

      state = %{
        base_state()
        | running: %{
            issue.id => %{pid: nil, ref: nil, identifier: issue.identifier, issue: issue}
          },
          claimed: MapSet.new([issue.id])
      }

      parent = self()

      result =
        CommentWake.mark_pr_merged_issue_done(state, issue.identifier,
          merged_by_login: "bad-actor",
          merger_allowed_fun: fn login ->
            send(parent, {:checked, login})
            false
          end,
          emit_alert_fun: fn name, _opts ->
            send(parent, {:alert, name})
            :ok
          end,
          update_issue_state_fun: fn _id, "done" -> :ok end,
          clear_session_handle_fun: fn _id -> :ok end,
          observe_membership_fun: fn _identity, _lc -> :ok end,
          set_terminal_verification_pending_fun: fn _identity, _pending? -> :ok end,
          terminate_running_issue_fun: fn s, id, true ->
            %{s | running: Map.delete(s.running, id), claimed: MapSet.new()}
          end
        )

      assert_receive {:checked, "bad-actor"}
      assert_receive {:alert, "ticket.99.merge.unauthorized_merger"}
      refute Map.has_key?(result.running, issue.id)
    end

    test "still terminates a merged issue when the merger allowlist check exits" do
      issue = %Issue{
        id: "issue-attribution-failure",
        identifier: "100",
        state: "in-progress",
        tracker_identity: tracker_identity("100")
      }

      state = %{
        base_state()
        | running: %{
            issue.id => %{pid: nil, ref: nil, identifier: issue.identifier, issue: issue}
          },
          claimed: MapSet.new([issue.id])
      }

      parent = self()

      result =
        CommentWake.mark_pr_merged_issue_done(state, issue.identifier,
          merged_by_login: "its-everdred",
          merger_allowed_fun: fn _login -> exit(:timeout) end,
          emit_alert_fun: fn name, opts ->
            send(parent, {:alert, name, opts})
            :ok
          end,
          update_issue_state_fun: fn _id, "done" -> :ok end,
          clear_session_handle_fun: fn _id -> :ok end,
          observe_membership_fun: fn _identity, _lifecycle -> :ok end,
          set_terminal_verification_pending_fun: fn _identity, _pending? -> :ok end,
          terminate_running_issue_fun: fn current_state, issue_id, true ->
            %{
              current_state
              | running: Map.delete(current_state.running, issue_id),
                claimed: MapSet.new()
            }
          end
        )

      assert_receive {:alert, "ticket.100.merge.attribution_check_failed", opts}
      assert Keyword.get(opts, :needs_attention) == true
      assert Keyword.get(opts, :severity) == "critical"
      refute Map.has_key?(result.running, issue.id)
      refute MapSet.member?(result.claimed, issue.id)
    end
  end

  defp tracker_identity(identifier) do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repository",
      provider_id: "I-#{identifier}",
      identifier: identifier,
      reason: nil
    }
  end
end
