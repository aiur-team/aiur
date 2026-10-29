defmodule Aiur.Orchestrator.CommentWake.OpenPrAndAttemptsTest do
  # Log capture is global; preserve the original module's serial execution.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.Issue
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

    # #2473 acceptance: a `CHANGES_REQUESTED` review submitted with a body and
    # no inline comments opens NO review thread, so #2422's unresolved-thread
    # read reports zero threads and the ticket never leaves
    # `agent:human-review` — the reviewer's verdict is silently dropped, with
    # no label write at all on the timeline. The review submission is itself
    # the outstanding finding and must route to rework.
    test "routes a body-only CHANGES_REQUESTED review submission to rework with zero review threads" do
      state = base_state()

      event = %{
        author_trusted?: true,
        comment: %{
          "body" => "This needs changes before it can merge.",
          "state" => "CHANGES_REQUESTED",
          "submitted_at" => "2026-09-01T02:03:20Z"
        },
        issue_state_fetcher: fn _ids -> {:ok, [rework_labelled_issue("2473")]} end,
        open_pr_fetcher: fn _issue_key -> {:ok, %{"number" => 42, "head" => %{"sha" => "abc123"}}} end,
        unresolved_threads_fetcher: fn _pr -> {:ok, []} end
      }

      log =
        capture_log(fn ->
          CommentWake.maybe_transition_idle_issue_to_rework(state, "2473", "pr review", event, 1)
        end)

      # The gate must be passed, not skipped: the unset tracker then fails the
      # write, which proves the `rework` write was actually attempted.
      refute log =~ ":no_unresolved_review_threads"
      refute log =~ "ignored for idle issue"
      assert log =~ "rework transition skipped"
    end

    # The two tests above read the write through a log proxy, because the
    # tracker adapter is global config and this module is `async: true`, so it
    # cannot be swapped for a recording fake without serialising the file. This
    # one asserts *positively* that control reached the rework write stage: the
    # rework-attempt bound runs immediately before the write and its alert
    # emitter is injectable, so a head already at the limit produces a message
    # that no earlier skip could produce.
    test "a body-only CHANGES_REQUESTED review reaches the rework write stage" do
      test_pid = self()

      state =
        Enum.reduce(1..State.rework_attempt_limit(), base_state(), fn _i, acc ->
          State.bump_rework_attempt(acc, "2473", "abc123")
        end)

      event = %{
        author_trusted?: true,
        comment: %{"body" => "This needs changes.", "state" => "CHANGES_REQUESTED"},
        issue_state_fetcher: fn _ids -> {:ok, [rework_labelled_issue("2473")]} end,
        open_pr_fetcher: fn _issue_key -> {:ok, %{"number" => 42, "head" => %{"sha" => "abc123"}}} end,
        unresolved_threads_fetcher: fn _pr -> {:ok, []} end,
        emit_alert_fun: fn topic, opts -> send(test_pid, {:alert, topic, opts}) end
      }

      capture_log(fn ->
        CommentWake.maybe_transition_idle_issue_to_rework(state, "2473", "pr review", event, 1)
      end)

      # The bound is only consulted after the thread gate has already allowed
      # the rework write, so receiving this proves the body-only review was
      # accepted as a rework signal.
      assert_receive {:alert, "ticket.2473.agent.attention.rework_attempt_limit", _opts}, 1000
    end

    # The lower-cased `state` a `pull_request_review` delivery carries must
    # route identically to the upper-cased one the poller reads, so the
    # webhook path and its polling backstop cannot disagree (#2473).
    test "routes a lower-cased changes_requested review state to rework as well" do
      state = base_state()

      event = %{
        author_trusted?: true,
        comment: %{"body" => "please fix", "state" => "changes_requested"},
        issue_state_fetcher: fn _ids -> {:ok, [rework_labelled_issue("2473")]} end,
        open_pr_fetcher: fn _issue_key -> {:ok, %{"number" => 42, "head" => %{"sha" => "abc123"}}} end,
        unresolved_threads_fetcher: fn _pr -> {:ok, []} end
      }

      log =
        capture_log(fn ->
          CommentWake.maybe_transition_idle_issue_to_rework(state, "2473", "pr review", event, 1)
        end)

      refute log =~ ":no_unresolved_review_threads"
      assert log =~ "rework transition skipped"
    end

    # The #2473 signal is scoped to a changes-requested review. An APPROVED or
    # blank COMMENTED review with no unresolved threads keeps #2422's refusal, so the
    # fix cannot reopen the rework loop it closed.
    test "keeps refusing rework for approved, dismissed or blank commented reviews with zero threads" do
      state = base_state()

      for review_state <- ["APPROVED", "COMMENTED", "DISMISSED"] do
        event = %{
          author_trusted?: true,
          comment: %{"body" => "  ", "state" => review_state},
          issue_state_fetcher: fn _ids -> {:ok, [rework_labelled_issue("2473")]} end,
          open_pr_fetcher: fn _issue_key -> {:ok, %{"number" => 42, "head" => %{"sha" => "abc123"}}} end,
          unresolved_threads_fetcher: fn _pr -> {:ok, []} end
        }

        {result, log} =
          with_log(fn ->
            CommentWake.maybe_transition_idle_issue_to_rework(state, "2473", "pr review", event, 1)
          end)

        assert log =~ ":no_unresolved_review_threads", "expected #{review_state} to keep the #2422 refusal"
        assert result == state
      end
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

      assert_receive {:alert_emitted, "ticket.2422.agent.attention.rework_attempt_limit", opts}, 1000
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
      refute_receive {:alert_emitted, _, _}, 100
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
      refute_receive {:alert_emitted, _, _}, 100
    end
  end
end
