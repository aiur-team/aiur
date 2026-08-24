defmodule Aiur.Orchestrator.ReworkReviewTransitionTest do
  @moduledoc """
  AC for #2337 (Cause 2): a `CHANGES_REQUESTED` review moves its ticket to the
  rework state with no manual relabel.

  The webhook and poll pipes both publish the review to
  `ticket.<id>.pr.review_comment`, which the orchestrator routes to
  `CommentWake`; `#1427` closed #1389 by making that path wake the agent. This
  file proves the terminal half of the chain: for a human-review ticket, a live
  CHANGES_REQUESTED review event reaches `Tracker.update_issue_state(ticket,
  "rework")` — the actual label write the Executor used to perform by hand.

  Uses the in-memory tracker adapter so the write is observable as a real
  `{:memory_tracker_state_update, issue_id, "rework"}` message instead of
  inferred from a log line. Sync (Aiur.TestSupport), because configuring the
  tracker adapter is a VM-global side effect that must not leak into the async
  `comment_wake_test.exs`.
  """

  use Aiur.TestSupport

  alias Aiur.{AgentQueueStore, Issue}
  alias Aiur.Orchestrator.{CommentWake, State}

  @issue_number "2337"

  defp base_state do
    %State{
      queue_store: AgentQueueStore.new(),
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
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

  # A human-review ticket is the exact case the manual `agent:human-review` →
  # `agent:rework` relabel used to compensate for (#2337 Cause 2, #1389).
  defp human_review_issue do
    %Issue{
      id: @issue_number,
      identifier: @issue_number,
      state: "human-review",
      title: "t",
      labels: ["agent:human-review"]
    }
  end

  # The shape the poll/webhook pipes publish: a live CHANGES_REQUESTED review
  # against the current head (not stale, not an APPROVED pull request), by a
  # CODEOWNERS-trusted author.
  defp changes_requested_review_event(issue) do
    %{
      author_trusted?: true,
      comment: %{
        "state" => "CHANGES_REQUESTED",
        "body" => "please fix the ranking test",
        "submitted_at" => "2026-08-22T21:30:00Z"
      },
      pull_request: %{
        "review_decision" => "CHANGES_REQUESTED",
        "head_committed_at" => "2026-08-22T20:00:00Z"
      },
      issue_state_fetcher: fn _ids -> {:ok, [issue]} end,
      open_pr_fetcher: fn _issue_key -> {:ok, %{"number" => 2337}} end
    }
  end

  test "a CHANGES_REQUESTED review moves a human-review ticket to rework" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "memory")

    Application.put_env(:aiur, :memory_tracker_issues, [human_review_issue()])
    Application.put_env(:aiur, :memory_tracker_recipient, self())

    state = base_state()
    issue = human_review_issue()
    event = changes_requested_review_event(issue)

    log =
      capture_log(fn ->
        CommentWake.maybe_transition_idle_issue_to_rework(state, @issue_number, :pr_review, event, 1)
      end)

    # The rework write is a real tracker mutation, not just a routed event.
    assert_receive {:memory_tracker_state_update, @issue_number, "rework"}, 1_000
    refute log =~ "ignored for idle issue"
    refute log =~ ":no_open_pr"
    refute log =~ ":stale_review"
  end

  test "an APPROVED review does not move a human-review ticket to rework" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "memory")

    Application.put_env(:aiur, :memory_tracker_issues, [human_review_issue()])
    Application.put_env(:aiur, :memory_tracker_recipient, self())

    state = base_state()
    issue = human_review_issue()

    event =
      changes_requested_review_event(issue)
      |> Map.put(:comment, %{"state" => "APPROVED", "body" => "nice work", "submitted_at" => "2026-08-22T21:30:00Z"})
      |> Map.put(:pull_request, %{"review_decision" => "APPROVED", "head_committed_at" => "2026-08-22T20:00:00Z"})

    log =
      capture_log(fn ->
        CommentWake.maybe_transition_idle_issue_to_rework(state, @issue_number, :pr_review, event, 1)
      end)

    refute_received {:memory_tracker_state_update, @issue_number, "rework"}
    assert log =~ "ignored for idle issue"
    assert log =~ ":approved_pull_request"
  end
end
