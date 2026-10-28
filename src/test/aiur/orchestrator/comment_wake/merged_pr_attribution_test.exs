defmodule Aiur.Orchestrator.CommentWake.MergedPrAttributionTest do
  # Log capture is global; preserve the original module's serial execution.
  use ExUnit.Case, async: false

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
      github_connectivity: %{},
      github_poll_delays: %{}
    }
  end

  describe "mark_pr_merged_issue_done/2" do
    test "ticket branch with Refs only in a commit comments without changing state" do
      parent = self()

      result =
        CommentWake.mark_pr_merged_issue_done(base_state(), "5605",
          pr_body: "",
          commit_messages: ["Refs #5605"],
          pr_number: 5606,
          pr_url: "https://github.com/owner/repo/pull/5606",
          repository: "owner/repo",
          update_issue_state_fun: fn identifier, target ->
            send(parent, {:transition, identifier, target})
            :ok
          end,
          create_comment_fun: fn identifier, body ->
            send(parent, {:comment, identifier, body})
            :ok
          end,
          merged_by_login: "its-everdred",
          merger_allowed_fun: fn _ -> true end
        )

      assert is_struct(result, State)
      assert_receive {:comment, "5605", body}, 1000
      assert body =~ "PR 5606 referencing this ticket merged"
      refute_receive {:transition, _, _}, 100
    end

    test "does not raise alert when merged_by_login is allowlisted" do
      state = base_state()
      parent = self()

      CommentWake.mark_pr_merged_issue_done(state, "424242",
        pr_body: "Closes #424242",
        merged_by_login: "its-everdred",
        update_issue_state_fun: fn _id, "done" -> :ok end,
        merger_allowed_fun: fn login ->
          send(parent, {:checked_allowlist, login})
          true
        end,
        emit_alert_fun: fn _name, _opts ->
          send(parent, :unexpected_alert)
          :ok
        end,
        open_pull_requests_fun: fn _identifier -> {:ok, []} end
      )

      assert_receive {:checked_allowlist, "its-everdred"}, 1000
      refute_receive :unexpected_alert, 100
    end

    test "emits unauthorized-merger alert when merged_by_login is not allowlisted" do
      state = base_state()
      parent = self()

      CommentWake.mark_pr_merged_issue_done(state, "424242",
        pr_body: "Closes #424242",
        merged_by_login: "unknown-bot",
        update_issue_state_fun: fn _id, "done" -> :ok end,
        merger_allowed_fun: fn login ->
          send(parent, {:checked_allowlist, login})
          false
        end,
        emit_alert_fun: fn name, opts ->
          send(parent, {:alert_emitted, name, opts})
          :ok
        end,
        open_pull_requests_fun: fn _identifier -> {:ok, []} end
      )

      assert_receive {:checked_allowlist, "unknown-bot"}, 1000
      assert_receive {:alert_emitted, "ticket.424242.merge.unauthorized_merger", opts}, 1000
      assert Keyword.get(opts, :needs_attention) == true
      assert Keyword.get(opts, :severity) == "critical"
      assert Keyword.get(opts, :issue) == "424242"
      assert Keyword.get(opts, :reason) =~ "unknown-bot"
    end

    # A merge that carries no merger login is UNVERIFIED, not unauthorized. It
    # still raises a critical, needs-attention alert -- the guard stays
    # fail-closed -- but under the name and wording that say which of the two
    # it is. An allowlisted human merging with `gh pr merge --squash` produced
    # this on a live fleet, and "Unauthorized PR merger nil detected" is how a
    # security alert gets muted; once muted it can no longer distinguish a real
    # unauthorized merge from a failed read, which is its entire job.
    test "an absent merger login is reported as unverified, not as unauthorized" do
      state = base_state()
      parent = self()

      for absent <- [nil, ""] do
        CommentWake.mark_pr_merged_issue_done(state, "424242",
          pr_body: "Closes #424242",
          merged_by_login: absent,
          update_issue_state_fun: fn _id, "done" -> :ok end,
          merger_allowed_fun: fn login ->
            send(parent, {:checked_allowlist, login})
            false
          end,
          emit_alert_fun: fn name, opts ->
            send(parent, {:alert_emitted, name, opts})
            :ok
          end,
          open_pull_requests_fun: fn _identifier -> {:ok, []} end
        )

        assert_receive {:alert_emitted, "ticket.424242.merge.attribution_check_failed", opts}, 1000
        refute_received {:alert_emitted, "ticket.424242.merge.unauthorized_merger", _opts}

        # The allowlist is never consulted: "is nil allowed?" has no meaningful
        # answer, and asking it is what produced the accusatory wording.
        refute_received {:checked_allowlist, _login}

        # Still fail-closed.
        assert Keyword.get(opts, :needs_attention) == true
        assert Keyword.get(opts, :severity) == "critical"
        assert Keyword.get(opts, :reason) =~ "not a detected unauthorized one"
      end
    end

    test "still emits unauthorized-merger alert when tracker update fails" do
      state = base_state()
      parent = self()

      result =
        CommentWake.mark_pr_merged_issue_done(state, "424242",
          pr_body: "Closes #424242",
          merged_by_login: "unknown-bot",
          update_issue_state_fun: fn _id, "done" -> {:error, :unavailable} end,
          merger_allowed_fun: fn _login -> false end,
          emit_alert_fun: fn name, opts ->
            send(parent, {:alert_emitted, name, opts})
            :ok
          end,
          open_pull_requests_fun: fn _identifier -> {:ok, []} end
        )

      assert_receive {:alert_emitted, "ticket.424242.merge.unauthorized_merger", opts}, 1000
      assert Keyword.get(opts, :needs_attention) == true
      assert Keyword.get(opts, :severity) == "critical"
      assert result == state
    end

    test "default emitter supplies an explicit system alert message" do
      state = base_state()

      log =
        capture_log(fn ->
          assert CommentWake.mark_pr_merged_issue_done(state, "424242",
                   pr_body: "Closes #424242",
                   merged_by_login: "unknown-bot",
                   update_issue_state_fun: fn _id, "done" -> :ok end,
                   merger_allowed_fun: fn _login -> false end,
                   open_pull_requests_fun: fn _identifier -> {:ok, []} end
                 ) == state
        end)

      assert log =~
               "[alert] (#424242) ticket.424242.merge.unauthorized_merger"

      assert log =~ "Unauthorized PR merger \"unknown-bot\" detected for ticket 424242."
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
          pr_body: "Closes #99",
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
          end,
          open_pull_requests_fun: fn _identifier -> {:ok, []} end
        )

      assert_receive {:checked, "bad-actor"}, 1000
      assert_receive {:alert, "ticket.99.merge.unauthorized_merger"}, 1000
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
          pr_body: "Closes #100",
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
          end,
          open_pull_requests_fun: fn _identifier -> {:ok, []} end
        )

      assert_receive {:alert, "ticket.100.merge.attribution_check_failed", opts}, 1000
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
