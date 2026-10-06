defmodule Aiur.Orchestrator.CommentReworkActiveEntryTest do
  @moduledoc """
  A `CHANGES_REQUESTED` review that lands while the ticket still holds a running
  entry must still reach `agent:rework`.

  `CommentWake.maybe_reactivate_on_comment/5` routes on the running entry's
  shape. Two shapes were covered: no entry at all (the idle writer, which
  retries a transient failure through `{:retry_comment_rework, ...}`), and a
  `:deactivated` entry (the write-then-reactivate path). The third shape — an
  entry that is present but *not* `:deactivated` — is what a worker that just
  finished its turn leaves behind (`control.status: :completed`), and what a
  ticket that bounced `human-review` → `ci-wait` → `human-review` keeps across
  the round trip. That shape went to `protect_active_comment_delivery/6`, which
  discarded every non-`:ok` gate outcome with no retry, no alert and no log
  line.

  A review submission is delivered once: `Aiur.Events.Publisher` holds
  `{:pr_review, owner, repo, review_id}` for 72h and the poller's
  `pr_review_seen_at` watermark advances past the review's `submitted_at` in the
  cycle that read it. So a single transient refusal on this path was permanent —
  the ticket stayed in `agent:human-review` until an operator relabelled it.

  Sync (`Aiur.TestSupport`), because the in-memory tracker adapter is a
  VM-global setting.
  """

  use Aiur.TestSupport

  alias Aiur.{AgentQueueStore, Issue}
  alias Aiur.Orchestrator.{CommentWake, State}

  @issue_number "2814"

  defp base_state(running) do
    %State{
      queue_store: AgentQueueStore.new(),
      running: running,
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

  # The shape observed on every failing ticket: the provider's turn has
  # completed, the entry is still in `state.running`, and `control.status` is
  # `:completed` rather than `:deactivated`.
  defp completed_running_entry do
    %{
      "2814" => %{
        identifier: @issue_number,
        issue: %Issue{
          id: @issue_number,
          identifier: @issue_number,
          state: "human-review",
          title: "t",
          labels: ["agent:human-review"]
        },
        pid: nil,
        telemetry_attempt_id: "ticket-2814:test",
        control: %{status: :completed, version: 1}
      }
    }
  end

  defp human_review_issue do
    %Issue{
      id: @issue_number,
      identifier: @issue_number,
      state: "human-review",
      title: "t",
      labels: ["agent:human-review"]
    }
  end

  # A body-only `gh pr review --request-changes`: live against the current head,
  # by a trusted author, opening no review thread at all.
  defp changes_requested_review_event(issue, overrides) do
    %{
      topic: "ticket.#{@issue_number}.pr.review_comment",
      author_trusted?: true,
      comment: %{
        "state" => "CHANGES_REQUESTED",
        "body" => "two blockers before this can merge",
        "submitted_at" => "2026-09-26T04:09:44Z"
      },
      pull_request: %{
        "review_decision" => "CHANGES_REQUESTED",
        "head_committed_at" => "2026-09-26T03:59:38Z"
      },
      issue_state_fetcher: fn _ids -> {:ok, [issue]} end,
      open_pr_fetcher: fn _issue_key -> {:ok, %{"number" => 337, "head" => %{"sha" => "52617e7"}}} end
    }
    |> Map.merge(overrides)
  end

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "memory")

    Application.put_env(:aiur, :memory_tracker_issues, [human_review_issue()])
    Application.put_env(:aiur, :memory_tracker_recipient, self())
    Application.put_env(:aiur, :comment_rework_retry_delay_ms, 5)

    on_exit(fn -> Application.delete_env(:aiur, :comment_rework_retry_delay_ms) end)

    :ok
  end

  test "a transient gate failure on a completed running entry is retried, not dropped" do
    issue = human_review_issue()

    reads = :counters.new(1, [])

    event =
      changes_requested_review_event(issue, %{
        unresolved_threads_fetcher: fn _pr ->
          :counters.add(reads, 1, 1)

          case :counters.get(reads, 1) do
            1 -> {:error, {:github, :http, %{status: 502}}}
            _ -> {:ok, []}
          end
        end
      })

    state = base_state(completed_running_entry())

    capture_log(fn ->
      CommentWake.maybe_reactivate_on_comment(state, @issue_number, :pr_review, event, 1)
    end)

    # The first attempt failed transiently, so the review must come back.
    assert_receive {:retry_comment_rework, @issue_number, :pr_review, retried_event, 2}, 2_000

    capture_log(fn ->
      CommentWake.maybe_reactivate_on_comment(state, @issue_number, :pr_review, retried_event, 2)
    end)

    # …and the retry writes the label the operator used to write by hand.
    assert_receive {:memory_tracker_state_update, @issue_number, "rework"}, 2_000
  end

  test "a refused changes-requested review on a completed running entry raises attention" do
    issue = human_review_issue()
    test_pid = self()

    event =
      changes_requested_review_event(issue, %{
        # The ticket has no open pull request any more, so the gate refuses the
        # verdict — correctly — and the refusal must not be silent.
        open_pr_fetcher: fn _issue_key -> {:ok, :no_open_pr} end,
        emit_alert_fun: fn topic, opts -> send(test_pid, {:alert, topic, opts}) end
      })

    state = base_state(completed_running_entry())

    log =
      capture_log(fn ->
        CommentWake.maybe_reactivate_on_comment(state, @issue_number, :pr_review, event, 1)
      end)

    refute_received {:memory_tracker_state_update, @issue_number, "rework"}

    assert_receive {:alert, "ticket.2814.agent.attention.review_rework_refused", opts}, 1_000
    assert Keyword.get(opts, :needs_attention) == true
    assert log =~ "refused rework for a changes-requested review"
    assert log =~ ":no_open_pr"
  end

  test "a plain comment whose threads are clear stays quiet" do
    issue = human_review_issue()
    test_pid = self()

    event =
      changes_requested_review_event(issue, %{
        comment: %{"body" => "just a note", "created_at" => "2026-09-26T04:09:44Z"},
        unresolved_threads_fetcher: fn _pr -> {:ok, []} end,
        emit_alert_fun: fn topic, opts -> send(test_pid, {:alert, topic, opts}) end
      })

    state = base_state(completed_running_entry())

    capture_log(fn ->
      CommentWake.maybe_reactivate_on_comment(state, @issue_number, :pr_review, event, 1)
    end)

    refute_received {:alert, "ticket.2814.agent.attention.review_rework_refused", _opts}
    refute_received {:memory_tracker_state_update, @issue_number, "rework"}
  end
end
