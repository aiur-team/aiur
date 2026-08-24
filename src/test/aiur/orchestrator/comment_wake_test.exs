defmodule Aiur.Orchestrator.CommentWakeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Aiur.{AgentQueueStore, Issue, TrackerIdentity}
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
  #
  # #1971: the gate resolves the idle issue's current state first and only routes
  # a comment to rework when the ticket carries an `agent:*` state label. These
  # fixtures inject an `issue_state_fetcher` returning a *labelled* issue so the
  # review-freshness rules (not the unlabelled gate) are the thing under test.
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

  # #2075: `rework` requires work that exists and was rejected, and the one
  # unambiguous precondition every writer needs is "an open PR exists". A
  # trusted comment on a ticket with no open PR must be refused at the source —
  # stamping `rework` on absent work asserts a review verdict that never
  # happened, strands the ticket in a state nothing selects, and costs the
  # dispatched agent a turn discovering there is nothing to rework (#1844).
  # This is the precondition test for the comment_wake writer.
  describe "maybe_transition_idle_issue_to_rework/5 open-PR precondition (#2075)" do
    defp rework_labelled_issue(number, state \\ "human-review") do
      %Issue{id: number, identifier: number, state: state, title: "t", labels: ["agent:#{state}"]}
    end

    test "refuses rework at the source when the ticket has no open PR" do
      state = base_state()

      event = %{
        author_trusted?: true,
        comment: %{"body" => "please fix"},
        issue_state_fetcher: fn _ids -> {:ok, [rework_labelled_issue("2075")]} end,
        open_pr_fetcher: fn _issue_key -> {:ok, nil} end
      }

      log =
        capture_log(fn ->
          assert CommentWake.maybe_transition_idle_issue_to_rework(state, "2075", "issue comment", event, 1) == state
        end)

      assert log =~ "ignored for idle issue"
      assert log =~ ":no_open_pr"

      # The refusal is deterministic (no open PR exists), not a transient
      # failure, so no retry is scheduled.
      assert state.comment_rework_retries == %{}
    end

    test "writes rework when an open PR exists with unresolved review threads" do
      # Control: with an open PR that still has unresolved review threads, the
      # trusted-comment writer reaches the tracker update. The unset tracker
      # fails the write (permanently, here a 404), so the write is skipped and
      # reported — proving the gate passed and the `rework` write was actually
      # attempted.
      state = base_state()

      event = %{
        author_trusted?: true,
        comment: %{"body" => "please fix"},
        issue_state_fetcher: fn _ids -> {:ok, [rework_labelled_issue("2075")]} end,
        open_pr_fetcher: fn _issue_key -> {:ok, %{"number" => 42, "head" => %{"sha" => "abc123"}}} end,
        unresolved_threads_fetcher: fn _pr -> {:ok, [%{"id" => "thread-1"}]} end
      }

      log =
        capture_log(fn ->
          CommentWake.maybe_transition_idle_issue_to_rework(state, "2075", "issue comment", event, 1)
        end)

      refute log =~ "ignored for idle issue"
      refute log =~ ":no_open_pr"
      refute log =~ ":no_unresolved_review_threads"
      assert log =~ "rework transition skipped"
    end

    # #2422 acceptance: a pull request whose `reviewDecision` is
    # `CHANGES_REQUESTED` but whose review threads are all resolved (or that has
    # none) is not a rework target. GitHub never clears the verdict when
    # findings are addressed, so routing on the verdict alone re-enters
    # `agent:rework` forever. Unresolved review threads are the routing signal.
    test "does not route a CHANGES_REQUESTED PR with zero unresolved review threads to rework" do
      state = base_state()

      event = %{
        author_trusted?: true,
        comment: %{"body" => "rework complete"},
        issue_state_fetcher: fn _ids -> {:ok, [rework_labelled_issue("2422")]} end,
        open_pr_fetcher: fn _issue_key -> {:ok, %{"number" => 42, "head" => %{"sha" => "abc123"}}} end,
        unresolved_threads_fetcher: fn _pr -> {:ok, []} end
      }

      {result, log} =
        with_log(fn ->
          CommentWake.maybe_transition_idle_issue_to_rework(state, "2422", "issue comment", event, 1)
        end)

      # The routing decision is a *named* skip, not a silent nothing: a router
      # that returned "not rework" with no specific state would strand the
      # ticket at zero state labels (#2420). The named reason proves the gate
      # read the thread state and deliberately left the ticket in its current
      # `human-review` state — the returned orchestrator state is untouched.
      assert log =~ "ignored for idle issue"
      assert log =~ ":no_unresolved_review_threads"
      refute log =~ "rework transition skipped"
      assert result == state
      assert state.comment_rework_retries == %{}
    end

    test "a CHANGES_REQUESTED PR with unresolved review threads still routes to rework" do
      # #2422 acceptance, control: unresolved threads mean the reviewer is still
      # asking for a change, so the routing decision is unchanged from before.
      state = base_state()

      event = %{
        author_trusted?: true,
        comment: %{"body" => "please fix"},
        issue_state_fetcher: fn _ids -> {:ok, [rework_labelled_issue("2422")]} end,
        open_pr_fetcher: fn _issue_key -> {:ok, %{"number" => 42, "head" => %{"sha" => "abc123"}}} end,
        unresolved_threads_fetcher: fn _pr -> {:ok, [%{"id" => "thread-1"}]} end
      }

      log =
        capture_log(fn ->
          CommentWake.maybe_transition_idle_issue_to_rework(state, "2422", "issue comment", event, 1)
        end)

      refute log =~ ":no_unresolved_review_threads"
      assert log =~ "rework transition skipped"
    end
  end

  # #2422 acceptance: a ticket cannot enter `agent:rework` more than N times for
  # the same head SHA. When the bound is exhausted the routing stops and raises
  # attention once, instead of looping and consuming a slot every wake.
  describe "maybe_transition_idle_issue_to_rework/5 rework-attempt bound (#2422)" do
    defp rework_issue(number) do
      %Issue{id: number, identifier: number, state: "human-review", title: "t", labels: ["agent:human-review"]}
    end

    defp rework_comment_event(number) do
      %{
        author_trusted?: true,
        comment: %{"body" => "please fix"},
        issue_state_fetcher: fn _ids -> {:ok, [rework_issue(number)]} end,
        open_pr_fetcher: fn _issue_key -> {:ok, %{"number" => 42, "head" => %{"sha" => "abc123"}}} end,
        unresolved_threads_fetcher: fn _pr -> {:ok, [%{"id" => "thread-1"}]} end
      }
    end

    test "does not consume the bound when the rework write fails" do
      # The bound only consumes on a *successful* rework write: a failed tracker
      # write must not exhaust it, or one transient failure would permanently
      # silence a ticket that genuinely needs rework.
      state = base_state()

      {result, log} =
        with_log(fn ->
          CommentWake.maybe_transition_idle_issue_to_rework(state, "2422", "issue comment", rework_comment_event("2422"), 1)
        end)

      # The unset tracker fails the write, so no bump lands.
      assert log =~ "rework transition skipped"
      assert result.rework_attempts == %{}
    end

    test "refuses rework and raises attention once when the same head exceeds the bound" do
      state = %{base_state() | rework_attempts: %{{"2422", "abc123"} => State.rework_attempt_limit()}}
      parent = self()

      event =
        rework_comment_event("2422")
        |> Map.put(:emit_alert_fun, fn name, opts ->
          send(parent, {:alert_emitted, name, opts})
          :ok
        end)

      {result, log} =
        with_log(fn ->
          CommentWake.maybe_transition_idle_issue_to_rework(state, "2422", "issue comment", event, 1)
        end)

      # The routing stopped with a named reason, and the rework writer was never
      # reached — no further rework write, no further dispatch to a rework turn.
      assert log =~ ":rework_attempt_limit_reached"
      refute log =~ "rework transition skipped"
      assert state.comment_rework_retries == %{}

      assert_receive {:alert_emitted, "ticket.2422.agent.attention.rework_attempt_limit", opts}
      assert Keyword.get(opts, :needs_attention) == true
      assert Keyword.get(opts, :severity) == "warning"

      # The attention is raised exactly once per (issue, head): the signature is
      # recorded so a later wake does not re-emit it.
      assert MapSet.member?(result.rework_attempt_alerted, {"2422", "abc123"})
      assert result.rework_attempts == state.rework_attempts
    end

    test "does not raise the attention a second time for the same head" do
      state = %{
        base_state()
        | rework_attempts: %{{"2422", "abc123"} => State.rework_attempt_limit()},
          rework_attempt_alerted: MapSet.new([{"2422", "abc123"}])
      }

      parent = self()

      event =
        rework_comment_event("2422")
        |> Map.put(:emit_alert_fun, fn name, opts ->
          send(parent, {:alert_emitted, name, opts})
          :ok
        end)

      {result, log} =
        with_log(fn ->
          CommentWake.maybe_transition_idle_issue_to_rework(state, "2422", "issue comment", event, 1)
        end)

      assert log =~ ":rework_attempt_limit_reached"
      refute_receive {:alert_emitted, _, _}
      assert MapSet.member?(result.rework_attempt_alerted, {"2422", "abc123"})
    end

    test "a new head SHA is not bound by the old head's count" do
      # A genuine rework push changes the head SHA, so the bound starts fresh:
      # the rework write for the new head is attempted again.
      state = %{base_state() | rework_attempts: %{{"2422", "abc123"} => State.rework_attempt_limit()}}
      parent = self()

      event =
        rework_comment_event("2422")
        |> Map.put(:open_pr_fetcher, fn _issue_key -> {:ok, %{"number" => 42, "head" => %{"sha" => "newhead"}}} end)
        |> Map.put(:emit_alert_fun, fn name, opts ->
          send(parent, {:alert_emitted, name, opts})
          :ok
        end)

      {_result, log} =
        with_log(fn ->
          CommentWake.maybe_transition_idle_issue_to_rework(state, "2422", "issue comment", event, 1)
        end)

      refute log =~ ":rework_attempt_limit_reached"
      assert log =~ "rework transition skipped"
      refute_receive {:alert_emitted, _, _}
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

  # Regression coverage for #1747. A comment-rework retry chain runs on the
  # long-lived orchestrator for ~60s at the default settings, so a chain that can
  # never succeed keeps emitting warnings long after the work that started it —
  # in CI, straight into whichever unrelated `capture_log` assertion is running.
  describe "retryable_comment_rework_failure?/1" do
    test "a missing GitHub token is permanent, so it must not be retried" do
      refute CommentWake.retryable_comment_rework_failure?(:missing_github_token)
    end

    test "auth and permission classifications are permanent" do
      refute CommentWake.retryable_comment_rework_failure?({:github, :auth, %{status: 401}})
      refute CommentWake.retryable_comment_rework_failure?({:github, :permission, %{status: 403}})
    end

    test "client errors are permanent" do
      refute CommentWake.retryable_comment_rework_failure?({:github_api_status, 404})
      refute CommentWake.retryable_comment_rework_failure?({:github, :http, %{status: 422}})
    end

    test "server errors and transport faults are retryable" do
      assert CommentWake.retryable_comment_rework_failure?({:github_api_status, 502})
      assert CommentWake.retryable_comment_rework_failure?({:github, :http, %{status: 500}})
      assert CommentWake.retryable_comment_rework_failure?({:github, :timeout, %{reason: :timeout}})
      assert CommentWake.retryable_comment_rework_failure?({:github, :dns, %{reason: :nxdomain}})
    end

    test "request timeout and rate limiting stay retryable despite being 4xx" do
      assert CommentWake.retryable_comment_rework_failure?({:github_api_status, 408})
      assert CommentWake.retryable_comment_rework_failure?({:github_api_status, 429})
      assert CommentWake.retryable_comment_rework_failure?({:github, :rate_limited, %{status: 403}})
    end

    test "an unrecognised reason stays retryable" do
      assert CommentWake.retryable_comment_rework_failure?(:something_new)
    end
  end

  describe "comment-rework retry timer lifecycle" do
    defp tracked_retry_state(delay_ms) do
      issue_number = "1747"
      source = "issue comment"
      message = {:retry_comment_rework, issue_number, source, %{}, 2}
      timer_ref = Process.send_after(self(), message, delay_ms)

      state = %{
        base_state()
        | comment_rework_retries: %{
            CommentWake.comment_rework_retry_key(issue_number, source) => {timer_ref, issue_number, source}
          }
      }

      {state, timer_ref}
    end

    test "cancel_comment_rework_retries/1 stops a pending timer and clears tracking" do
      {state, timer_ref} = tracked_retry_state(100)

      cleared = CommentWake.cancel_comment_rework_retries(state)

      assert cleared.comment_rework_retries == %{}
      assert Process.read_timer(timer_ref) == false
      refute_receive {:retry_comment_rework, _issue, _source, _event, _attempt}, 300
    end

    test "cancel_comment_rework_retries/1 drops a retry that already fired" do
      {state, timer_ref} = tracked_retry_state(1)

      # Let the timer fire so its message is sitting in the mailbox: cancelling
      # alone would not stop that delivered retry from being processed.
      wait_until_timer_fired(timer_ref)

      cleared = CommentWake.cancel_comment_rework_retries(state)

      assert cleared.comment_rework_retries == %{}
      refute_received {:retry_comment_rework, _issue, _source, _event, _attempt}
    end

    test "cancel_comment_rework_retries/1 leaves unrelated mailbox messages alone" do
      {state, _timer_ref} = tracked_retry_state(100)
      send(self(), :unrelated_before)

      CommentWake.cancel_comment_rework_retries(state)

      assert_received :unrelated_before
    end

    test "forget_comment_rework_retry/3 drops the ref without cancelling" do
      {state, timer_ref} = tracked_retry_state(5_000)

      forgotten = CommentWake.forget_comment_rework_retry(state, "1747", "issue comment")

      assert forgotten.comment_rework_retries == %{}
      assert is_integer(Process.read_timer(timer_ref))
      Process.cancel_timer(timer_ref)
    end

    test "cancel_comment_rework_retries/1 tolerates a state with no tracked retries" do
      assert CommentWake.cancel_comment_rework_retries(base_state()).comment_rework_retries == %{}
    end

    defp wait_until_timer_fired(timer_ref, attempts \\ 100) do
      cond do
        Process.read_timer(timer_ref) == false -> :ok
        attempts == 0 -> flunk("timer did not fire")
        true -> Process.sleep(5) && wait_until_timer_fired(timer_ref, attempts - 1)
      end
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

      result =
        CommentWake.mark_pr_merged_issue_done(state, "nonexistent-123", open_pull_requests_fun: fn _identifier -> {:ok, []} end)

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
          merger_allowed_fun: fn _login -> true end,
          open_pull_requests_fun: fn _identifier -> {:ok, []} end
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
        end,
        open_pull_requests_fun: fn _identifier -> {:ok, []} end
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
        end,
        open_pull_requests_fun: fn _identifier -> {:ok, []} end
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
        end,
        open_pull_requests_fun: fn _identifier -> {:ok, []} end
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
          end,
          open_pull_requests_fun: fn _identifier -> {:ok, []} end
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
                   merger_allowed_fun: fn _login -> false end,
                   open_pull_requests_fun: fn _identifier -> {:ok, []} end
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
          end,
          open_pull_requests_fun: fn _identifier -> {:ok, []} end
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
          end,
          open_pull_requests_fun: fn _identifier -> {:ok, []} end
        )

      assert_receive {:alert, "ticket.100.merge.attribution_check_failed", opts}
      assert Keyword.get(opts, :needs_attention) == true
      assert Keyword.get(opts, :severity) == "critical"
      refute Map.has_key?(result.running, issue.id)
      refute MapSet.member?(result.claimed, issue.id)
    end

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
          end
        )

      assert_receive {:transition, "2307", "rework"}
      refute_receive {:transition, "2307", "done"}
      refute_receive :membership_recorded
      refute_receive :blockees_resumed
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
