defmodule Aiur.Orchestrator.CommentWake.MergedPrTargetsTest do
  # Log capture is global; preserve the original module's serial execution.
  use ExUnit.Case, async: false

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
    test "a merged PR whose ticket has other open PRs routes it to rework, never done, with no terminal teardown" do
      # The live webhook path (EventTopics {:pr_merged, id}) calls this without a
      # precomputed target_state, so the merge must not terminalize a ticket that
      # still has another open PR carrying CHANGES_REQUESTED: it lands in rework,
      # the running entry survives (no session clear / terminate / blockee resume),
      # and the remaining PR's findings stay dispatchable.
      issue = %Issue{
        id: "issue-remaining-open",
        identifier: "2307",
        state: "in-progress",
        tracker_identity: tracker_identity("2307")
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
          pr_body: "Closes #2307",
          merged_by_login: "its-everdred",
          update_issue_state_fun: fn identifier, state_name ->
            send(parent, {:transition, identifier, state_name})
            :ok
          end,
          observe_membership_fun: fn _identity, _lc ->
            send(parent, :membership_recorded)
            :ok
          end,
          resume_blockees_fun: fn current_state, _identifier ->
            send(parent, :blockees_resumed)
            current_state
          end,
          merger_allowed_fun: fn _login -> true end,
          open_pull_requests_fun: fn _identifier ->
            {:ok,
             [
               %{
                 "number" => 2318,
                 "head" => %{"ref" => "aiur/2307-agents-run-stale-budget"},
                 "review_decision" => "CHANGES_REQUESTED"
               }
             ]}
          end,
          # #2450: a CHANGES_REQUESTED verdict alone is not a rework signal —
          # the remaining PR must also carry genuinely unresolved review threads
          # for the ticket to land in rework.
          unresolved_threads_fetcher: fn _pr -> {:ok, [%{"id" => "thread-1"}]} end
        )

      assert_receive {:transition, "2307", "rework"}, 1000
      refute_receive {:transition, "2307", "done"}, 100
      refute_receive :membership_recorded, 100
      refute_receive :blockees_resumed, 100
      assert Map.has_key?(result.running, issue.id)
      assert MapSet.member?(result.claimed, issue.id)
    end

    test "a merged PR whose body only refs the ticket comments without changing state" do
      issue = %Issue{
        id: "issue-refs-only",
        identifier: "176",
        state: "human-review",
        tracker_identity: tracker_identity("176")
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
          pr_body: "Refs #176 (six operator gates remain)",
          pr_number: 901,
          pr_url: "https://github.com/owner/repo/pull/901",
          repository: "owner/repo",
          merged_by_login: "its-everdred",
          update_issue_state_fun: fn identifier, state_name ->
            send(parent, {:transition, identifier, state_name})
            :ok
          end,
          add_label_fun: fn identifier, label ->
            send(parent, {:label, identifier, label})
            :ok
          end,
          create_comment_fun: fn identifier, body ->
            send(parent, {:triage_comment, identifier, body})
            :ok
          end,
          clear_session_handle_fun: fn _identifier ->
            send(parent, :session_cleared)
            :ok
          end,
          observe_membership_fun: fn _identity, _lifecycle ->
            send(parent, :membership_recorded)
            :ok
          end,
          resume_blockees_fun: fn current_state, _identifier ->
            send(parent, :blockees_resumed)
            current_state
          end,
          merger_allowed_fun: fn _login -> true end,
          open_pull_requests_fun: fn _identifier ->
            flunk("a non-closing merge must not even enumerate the ticket's open PRs")
          end
        )

      refute_receive {:label, "176", _label}, 100
      refute_receive {:transition, "176", _state}, 100
      assert_receive {:triage_comment, "176", body}, 1000
      assert body =~ "PR 901 referencing this ticket merged"
      refute_receive {:transition, "176", "done"}, 100
      refute_receive :membership_recorded, 100
      refute_receive :session_cleared, 100
      refute_receive :blockees_resumed, 100
      assert Map.has_key?(result.running, issue.id)
      assert MapSet.member?(result.claimed, issue.id)
    end

    # #2609 fail-safe direction: no body is no closing evidence. The poll-cycle
    # reconciler reads the merge record's own body and closes a genuinely
    # closing ticket on the next pass, so leaving it open costs a poll; closing
    # it wrongly costs the operator their checklist.
    test "a merged PR with an empty body leaves its ticket open" do
      parent = self()

      CommentWake.mark_pr_merged_issue_done(base_state(), "176",
        pr_body: nil,
        merged_by_login: "its-everdred",
        update_issue_state_fun: fn identifier, state_name ->
          send(parent, {:transition, identifier, state_name})
          :ok
        end,
        merger_allowed_fun: fn _login -> true end,
        open_pull_requests_fun: fn _identifier -> {:ok, []} end
      )

      assert_receive {:transition, "176", "human-review"}, 1000
      refute_receive {:transition, "176", "done"}, 100
    end

    # A body naming the ticket mid-prose is not a closing keyword either — the
    # parser is deliberately no wider than GitHub's own rule.
    test "a merged PR that mentions the ticket without a keyword leaves it open" do
      parent = self()

      CommentWake.mark_pr_merged_issue_done(base_state(), "176",
        pr_body: "Delivers the non-live half of #176; see the checklist there.",
        merged_by_login: "its-everdred",
        update_issue_state_fun: fn identifier, state_name ->
          send(parent, {:transition, identifier, state_name})
          :ok
        end,
        merger_allowed_fun: fn _login -> true end,
        open_pull_requests_fun: fn _identifier -> {:ok, []} end
      )

      assert_receive {:transition, "176", "human-review"}, 1000
      refute_receive {:transition, "176", "done"}, 100
    end

    test "a same-repository qualified closing keyword still closes the ticket" do
      parent = self()

      CommentWake.mark_pr_merged_issue_done(base_state(), "176",
        pr_body: "Closes aiur-team/aiur#176",
        repo_fun: fn -> "aiur-team/aiur" end,
        merged_by_login: "its-everdred",
        update_issue_state_fun: fn identifier, state_name ->
          send(parent, {:transition, identifier, state_name})
          :ok
        end,
        clear_session_handle_fun: fn _identifier -> :ok end,
        merger_allowed_fun: fn _login -> true end,
        open_pull_requests_fun: fn _identifier -> {:ok, []} end
      )

      assert_receive {:transition, "176", "done"}, 1000
    end

    test "a closing keyword naming another repository's issue does not close this ticket" do
      parent = self()

      CommentWake.mark_pr_merged_issue_done(base_state(), "176",
        pr_body: "Closes other-org/other-repo#176",
        repo_fun: fn -> "aiur-team/aiur" end,
        merged_by_login: "its-everdred",
        update_issue_state_fun: fn identifier, state_name ->
          send(parent, {:transition, identifier, state_name})
          :ok
        end,
        merger_allowed_fun: fn _login -> true end,
        open_pull_requests_fun: fn _identifier -> {:ok, []} end
      )

      assert_receive {:transition, "176", "human-review"}, 1000
      refute_receive {:transition, "176", "done"}, 100
    end

    # A closing keyword for a *different* ticket is not a closing keyword for
    # this one: the branch names the ticket, the body has to name it too.
    test "a closing keyword for a different ticket does not close this one" do
      parent = self()

      CommentWake.mark_pr_merged_issue_done(base_state(), "176",
        pr_body: "Closes #999",
        merged_by_login: "its-everdred",
        update_issue_state_fun: fn identifier, state_name ->
          send(parent, {:transition, identifier, state_name})
          :ok
        end,
        merger_allowed_fun: fn _login -> true end,
        open_pull_requests_fun: fn _identifier -> {:ok, []} end
      )

      assert_receive {:transition, "176", "human-review"}, 1000
      refute_receive {:transition, "176", "done"}, 100
    end

    # A failing repository lookup must not fail the merge route: bare `#N` —
    # what every Aiur PR description carries — still closes normally.
    test "a raising repository lookup still lets a bare closing keyword close the ticket" do
      parent = self()

      CommentWake.mark_pr_merged_issue_done(base_state(), "176",
        pr_body: "Closes #176",
        repo_fun: fn -> raise "origin unavailable" end,
        merged_by_login: "its-everdred",
        update_issue_state_fun: fn identifier, state_name ->
          send(parent, {:transition, identifier, state_name})
          :ok
        end,
        clear_session_handle_fun: fn _identifier -> :ok end,
        merger_allowed_fun: fn _login -> true end,
        open_pull_requests_fun: fn _identifier -> {:ok, []} end
      )

      assert_receive {:transition, "176", "done"}, 1000
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
