defmodule Aiur.Orchestrator.CommentWake.TrustAndGatesTest do
  # Log capture is global; preserve the original module's serial execution.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.{AgentQueueStore, Issue}
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

  # #1756/#1971: these fixtures cover addressed findings and require a labelled
  # ticket before the freshness gate routes a comment to rework.
  describe "maybe_transition_idle_issue_to_rework/5 review-freshness gate" do
    @head_committed_at "2026-08-10T04:29:00Z"
    @stale_submitted_at "2026-08-08T21:15:00Z"

    defp labelled_issue(number, state \\ "human-review") do
      %Issue{id: number, identifier: number, state: state, title: "t", labels: ["agent:#{state}"]}
    end

    defp state_fetcher(event, issue) do
      Map.put(event, :issue_state_fetcher, fn _ids -> {:ok, [issue]} end)
    end

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
        "1583"
        |> labelled_issue()
        |> then(&state_fetcher(stale_review_event(%{"review_decision" => "CHANGES_REQUESTED", "head_committed_at" => @head_committed_at}), &1))

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
        "1747"
        |> labelled_issue()
        |> then(
          &state_fetcher(
            %{
              author_trusted?: true,
              comment: %{"body" => "nice work", "submitted_at" => "2026-08-10T06:00:00Z"},
              pull_request: %{"review_decision" => "APPROVED", "head_committed_at" => @head_committed_at}
            },
            &1
          )
        )

      log =
        capture_log(fn ->
          assert CommentWake.maybe_transition_idle_issue_to_rework(state, "1747", :pr_comment, event, 1) == state
        end)

      assert log =~ "ignored for idle issue"
      assert log =~ ":approved_pull_request"
    end

    test "still routes a review submitted against the current head" do
      # Guards the gate against over-skipping: a live CHANGES_REQUESTED review
      # on a *labelled* ticket must reach the tracker update rather than be
      # silently swallowed.
      state = base_state()

      event =
        "1583"
        |> labelled_issue()
        |> then(
          &state_fetcher(
            %{
              author_trusted?: true,
              comment: %{"state" => "CHANGES_REQUESTED", "body" => "please fix", "submitted_at" => "2026-08-10T05:00:00Z"},
              pull_request: %{"review_decision" => "CHANGES_REQUESTED", "head_committed_at" => @head_committed_at}
            },
            &1
          )
        )

      log =
        capture_log(fn ->
          CommentWake.maybe_transition_idle_issue_to_rework(state, "1583", :pr_review, event, 1)
        end)

      refute log =~ "ignored for idle issue"
    end
  end

  # #1971: a ticket with no `agent:*` state label is how an operator parks work
  # ("decide before this is built"). A trusted comment on such a ticket must NOT
  # auto-assign `agent:rework` — the invisible override this ticket exists to
  # kill. The explicit `agent:parked` marker is refused the same way.
  describe "maybe_transition_idle_issue_to_rework/5 parking gate" do
    defp parked_event(issue) do
      %{author_trusted?: true, issue_state_fetcher: fn _ids -> {:ok, [issue]} end}
    end

    test "does not route a trusted comment on a ticket with no agent:* label" do
      state = base_state()

      event =
        parked_event(%Issue{id: "1944", identifier: "1944", title: "t", labels: [], state: nil})

      log =
        capture_log(fn ->
          assert CommentWake.maybe_transition_idle_issue_to_rework(state, "1944", "issue comment", event, 1) == state
        end)

      assert log =~ "ignored for idle issue"
      assert log =~ ":unlabeled_issue"
      assert log =~ "ticket.1944.agent.attention.comment_wake_idle_issue"
    end

    test "does not route a trusted comment on an explicitly parked ticket even with an active label" do
      state = base_state()

      event =
        parked_event(%Issue{
          id: "1944",
          identifier: "1944",
          title: "t",
          labels: ["agent:todo", "agent:parked"],
          state: "todo",
          parked: true
        })

      log =
        capture_log(fn ->
          assert CommentWake.maybe_transition_idle_issue_to_rework(state, "1944", "issue comment", event, 1) == state
        end)

      assert log =~ "ignored for idle issue"
      assert log =~ ":parked"
    end

    test "uses the polled issue view when present instead of fetching" do
      state = %{base_state() | last_polled_issues: %{"1923" => labelled_issue("1923", "ci-wait")}}

      event =
        %{
          author_trusted?: true,
          issue_state_fetcher: fn _ids -> flunk("state fetcher must not be called when the polled view exists") end
        }

      log =
        capture_log(fn ->
          CommentWake.maybe_transition_idle_issue_to_rework(state, "1923", "issue comment", event, 1)
        end)

      # Reached the tracker update (unset tracker -> transient failure -> retry
      # scheduled), proving the labelled polled view passed the gate.
      refute log =~ "ignored for idle issue"
    end

    test "still routes when the tracker holds no record to read labels from" do
      # Trackers that do not index by id (and issues this repo does not own)
      # answer the gate's read with an empty list. Absence of a record is not
      # evidence of a park, so the gate must fail open to the pre-#1971 path
      # rather than swallow every comment on such a backend.
      state = base_state()

      event = %{author_trusted?: true, issue_state_fetcher: fn _ids -> {:ok, []} end}

      log =
        capture_log(fn ->
          CommentWake.maybe_transition_idle_issue_to_rework(state, "1971", "issue comment", event, 1)
        end)

      refute log =~ "ignored for idle issue"
    end
  end

  # A trusted comment on an `agent:todo` ticket must not flip it to
  # `agent:rework`. `rework` means "existing work needs redoing"; a `todo`
  # ticket has no work behind it, so the verdict is meaningless, it destroys
  # the true state (nothing restores `todo`), and it makes an operator triage
  # note indistinguishable from a reviewer rejecting the work. Labelling a
  # ticket `agent:todo` and then commenting to say why reliably un-promoted it
  # on the next poll cycle.
  #
  # Unlike the parked/unlabelled skips, this one MUST still seed the event
  # digest: a `todo` ticket is about to be dispatched, so the comment is
  # briefing material the agent has to read on its first turn. Skipping the
  # label transition must never mean losing operator input.
  describe "maybe_transition_idle_issue_to_rework/5 not-yet-attempted gate" do
    defp todo_issue(number) do
      %Issue{id: number, identifier: number, title: "t", labels: ["agent:todo"], state: "todo"}
    end

    defp todo_comment_event(number, body \\ "promoting this: the blocker cleared") do
      %{
        author_trusted?: true,
        id: 987_654,
        comment: %{"body" => body},
        issue_state_fetcher: fn _ids -> {:ok, [todo_issue(number)]} end
      }
    end

    test "does not route a trusted comment on an agent:todo ticket to rework" do
      state = %{base_state() | queue_store: AgentQueueStore.new()}

      {next_state, log} =
        with_log(fn ->
          CommentWake.maybe_transition_idle_issue_to_rework(state, "1739", "issue comment", todo_comment_event("1739"), 1)
        end)

      assert log =~ "ignored for idle issue"
      assert log =~ ":not_yet_attempted"

      # An attempted transition would hit the unset tracker, fail, and leave a
      # retry timer behind; no retry means the tracker write was never reached.
      refute log =~ "rework transition skipped"
      assert next_state.comment_rework_retries == %{}
    end

    test "still seeds the comment into the event digest the dispatched agent reads" do
      # The half of the fix that keeps the skip from becoming comment loss.
      state = %{base_state() | queue_store: AgentQueueStore.new()}
      event = todo_comment_event("1844", "read the linked spec before starting")

      {next_state, _log} =
        with_log(fn ->
          CommentWake.maybe_transition_idle_issue_to_rework(state, "1844", "issue comment", event, 1)
        end)

      digest_items =
        next_state.queue_store.items
        |> Map.values()
        |> Enum.filter(&(&1.event_type == :events_digest))

      assert [item] = digest_items
      assert item.target_issue_identifier == "1844"
      assert item.body.events == [event]
    end
  end
end
