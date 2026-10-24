defmodule Aiur.Orchestrator.CommentWake.MergedPrCompletionTest do
  # Log capture is global; preserve the original module's serial execution.
  use Aiur.TestSupport

  alias Aiur.{Issue, TrackerIdentity}
  alias Aiur.Orchestrator.{CommentWake, MergeStateWriter, State}

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
    test "skips terminal writes when the fetched issue belongs to another GitHub label prefix" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent"
      )

      issue = %Issue{id: "3163", identifier: "3163", state: nil, labels: ["nuc:done"]}

      result =
        MergeStateWriter.write_if_current("3163", "done", fetch_issue_states_fun: fn ["3163"] -> {:ok, [issue]} end)

      assert result == :skipped
    end

    test "does not complete or alert when the merged-PR writer skips a foreign lane" do
      state = base_state()
      parent = self()

      result =
        CommentWake.mark_pr_merged_issue_done(state, "3163",
          pr_body: "Closes #3163",
          update_issue_state_fun: fn "3163", "done" ->
            send(parent, :foreign_lane_writer_skipped)
            :skipped
          end,
          emit_alert_fun: fn _, _ -> flunk("a skipped foreign lane must not raise a transition alert") end,
          open_pull_requests_fun: fn _identifier -> {:ok, []} end
        )

      assert_received :foreign_lane_writer_skipped
      assert result == state
    end

    test "returns state unchanged when no matching running entry exists" do
      state = base_state()

      result =
        CommentWake.mark_pr_merged_issue_done(state, "424242", pr_body: "Closes #424242", open_pull_requests_fun: fn _identifier -> {:ok, []} end)

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
          pr_body: "Closes #42",
          update_issue_state_fun: fn _identifier, "done" -> :ok end,
          clear_session_handle_fun: fn _identifier -> :ok end,
          observe_membership_fun: fn identity, lifecycle ->
            send(parent, {:membership_recorded, identity, lifecycle})
            :ok
          end,
          set_terminal_verification_pending_fun: fn _identity, _pending? -> :ok end,
          terminate_running_issue_fun: fn current_state, issue_id, true ->
            assert_receive {:membership_recorded, ^identity, :completed}, 1000

            %{
              current_state
              | running: Map.delete(current_state.running, issue_id),
                claimed: MapSet.new()
            }
          end,
          merger_allowed_fun: fn _login -> true end,
          open_pull_requests_fun: fn _identifier -> {:ok, []} end
        )

      refute Map.has_key?(result.running, issue.id)
      refute MapSet.member?(result.claimed, issue.id)
    end

    # #2467: the merged-PR terminal path is the fourth site of the
    # hold-is-fatal defect. The open-PR lookup that decides the post-merge
    # target is a GitHub call, and a short self-clearing local budget hold on
    # it used to fire the merge-terminal-write alert and leave the ticket
    # stranded on its active-state label with its work complete (the #2457
    # incident). The shared helper waits the hold out, so the ticket still
    # reaches `done` and closes; the assertion is on the transition completing,
    # not on a log line.
    test "waits out a short local hold on the merged-PR open-PR lookup and completes the done transition" do
      issue = %Issue{
        id: "issue-hold-target",
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
      reset_at = DateTime.add(DateTime.utc_now(), 2, :second)
      hold = %{reason: :shared_budget, resource: "core", reset_at: reset_at}
      detail = %{reason: {:aiur, :locally_held, hold}, hold: hold}
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        CommentWake.mark_pr_merged_issue_done(state, issue.identifier,
          pr_body: "Closes #42",
          update_issue_state_fun: fn identifier, "done" ->
            send(parent, {:transitioned_to_done, identifier})
            :ok
          end,
          clear_session_handle_fun: fn _identifier -> :ok end,
          observe_membership_fun: fn identity, lifecycle ->
            send(parent, {:membership_recorded, identity, lifecycle})
            :ok
          end,
          set_terminal_verification_pending_fun: fn _identity, _pending? -> :ok end,
          terminate_running_issue_fun: fn current_state, issue_id, true ->
            assert_receive {:membership_recorded, ^identity, :completed}, 1000

            %{
              current_state
              | running: Map.delete(current_state.running, issue_id),
                claimed: MapSet.new()
            }
          end,
          merger_allowed_fun: fn _login -> true end,
          open_pull_requests_fun: fn _identifier ->
            attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
            if attempt == 1, do: {:error, {:github, :local_hold, detail}}, else: {:ok, []}
          end,
          local_hold_sleep_fun: fn _ms -> :ok end
        )

      assert_receive {:transitioned_to_done, "42"}, 1000
      refute Map.has_key?(result.running, issue.id)
      refute MapSet.member?(result.claimed, issue.id)
      # One held lookup, then a successful retry.
      assert Agent.get(counter, & &1) == 2
    end

    # #2467: the same hold, one step later — on the `done` terminal write
    # itself. Waited out, the write retries and the ticket still closes.
    test "waits out a short local hold on the merged-PR terminal write and closes the ticket" do
      issue = %Issue{
        id: "issue-hold-write",
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
      reset_at = DateTime.add(DateTime.utc_now(), 5, :minute)
      hold = %{reason: :shared_budget, resource: "core", reset_at: reset_at}
      detail = %{reason: {:aiur, :locally_held, hold}, hold: hold}
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      result =
        CommentWake.mark_pr_merged_issue_done(state, issue.identifier,
          pr_body: "Closes #42",
          update_issue_state_fun: fn identifier, "done" ->
            attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
            send(parent, {:terminal_write, identifier, attempt})
            if attempt == 1, do: {:error, {:github, :local_hold, detail}}, else: :ok
          end,
          clear_session_handle_fun: fn _identifier -> :ok end,
          observe_membership_fun: fn identity, lifecycle ->
            send(parent, {:membership_recorded, identity, lifecycle})
            :ok
          end,
          set_terminal_verification_pending_fun: fn _identity, _pending? -> :ok end,
          terminate_running_issue_fun: fn current_state, issue_id, true ->
            assert_receive {:membership_recorded, ^identity, :completed}, 1000

            %{
              current_state
              | running: Map.delete(current_state.running, issue_id),
                claimed: MapSet.new()
            }
          end,
          merger_allowed_fun: fn _login -> true end,
          open_pull_requests_fun: fn _identifier -> {:ok, []} end,
          local_hold_sleep_fun: fn _ms -> :ok end
        )

      assert_receive {:terminal_write, "42", 1}, 1000
      assert_receive {:terminal_write, "42", 2}, 1000
      refute Map.has_key?(result.running, issue.id)
      refute MapSet.member?(result.claimed, issue.id)
    end

    # #2467 mutation guard at this site: a hold whose `reset_at` is beyond the
    # ceiling is a genuine capacity problem and must still fail the terminal
    # path — the existing merge-terminal-write alert fires and no sleep happens.
    # Without this bound, waiting would be indistinguishable from swallowing the
    # error.
    test "a merged-PR local hold beyond the ceiling still fails and the existing alert fires" do
      state = base_state()
      reset_at = DateTime.add(DateTime.utc_now(), 3_700, :second)
      hold = %{reason: :shared_budget, resource: "core", reset_at: reset_at}
      detail = %{reason: {:aiur, :locally_held, hold}, hold: hold}

      log =
        capture_log(fn ->
          assert CommentWake.mark_pr_merged_issue_done(state, "424242",
                   pr_body: "Closes #424242",
                   open_pull_requests_fun: fn _identifier -> {:error, {:github, :local_hold, detail}} end,
                   local_hold_sleep_fun: fn _ms -> flunk("must not sleep for a beyond-ceiling hold") end
                 ) == state
        end)

      assert log =~
               "[alert] (#424242) ticket.424242.agent.attention.merge_terminal_write_failed"

      assert log =~ "Merged PR could not transition ticket 424242 to done"
    end

    # #2467 guard on the `done` write itself: a beyond-ceiling hold fails the
    # transition (skipped, no teardown) instead of being slept off indefinitely.
    test "a merged-PR terminal write hold beyond the ceiling still skips the transition" do
      issue = %Issue{
        id: "issue-hold-write-beyond",
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
      reset_at = DateTime.add(DateTime.utc_now(), 3_700, :second)
      hold = %{reason: :shared_budget, resource: "core", reset_at: reset_at}
      detail = %{reason: {:aiur, :locally_held, hold}, hold: hold}

      result =
        CommentWake.mark_pr_merged_issue_done(state, issue.identifier,
          pr_body: "Closes #42",
          update_issue_state_fun: fn _identifier, "done" -> {:error, {:github, :local_hold, detail}} end,
          observe_membership_fun: fn _identity, _lifecycle ->
            send(parent, :membership_recorded)
            :ok
          end,
          merger_allowed_fun: fn _login -> true end,
          open_pull_requests_fun: fn _identifier -> {:ok, []} end,
          local_hold_sleep_fun: fn _ms -> flunk("must not sleep for a beyond-ceiling hold") end
        )

      refute_receive :membership_recorded, 100
      assert Map.has_key?(result.running, issue.id)
      assert MapSet.member?(result.claimed, issue.id)
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
