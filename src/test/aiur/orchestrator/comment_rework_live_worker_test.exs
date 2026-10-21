defmodule Aiur.Orchestrator.CommentReworkLiveWorkerTest do
  use Aiur.TestSupport

  alias Aiur.{AgentQueueStore, AlertFeed, Issue}
  alias Aiur.Orchestrator.{CommentWake, State}

  @issue_number "4601"

  defp base_state(issue, status \\ :working) do
    %State{
      queue_store: AgentQueueStore.new(),
      running: %{
        @issue_number => %{
          identifier: @issue_number,
          issue: issue,
          pid: self(),
          telemetry_attempt_id: "ticket-4601:test",
          control: %{status: status, version: 1}
        }
      },
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      last_polled_issues: %{},
      github_connectivity: %{},
      github_poll_delays: %{}
    }
  end

  defp issue(state) do
    %Issue{id: @issue_number, identifier: @issue_number, state: state, title: "t", labels: ["agent:#{state}"]}
  end

  defp review_event(issue) do
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
      open_pr_fetcher: fn _issue_key -> {:ok, %{"number" => 337, "head" => %{"sha" => "52617e7"}}} end,
      unresolved_threads_fetcher: fn _pr -> {:ok, []} end
    }
  end

  setup do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:aiur, :memory_tracker_issues, [issue("human-review")])
    Application.put_env(:aiur, :memory_tracker_recipient, self())
    :ok
  end

  # Regression guard: origin/main already passes this. It is the only test of
  # a review reaching a live (`:working`) worker; the new behavior is the
  # already-rework no-op below.
  test "regression guard: a changes-requested review reaches a held worker without dispatch decline" do
    ticket = issue("human-review")
    state = base_state(ticket)
    event = review_event(ticket)

    updated = CommentWake.maybe_reactivate_on_comment(state, @issue_number, :pr_review, event)

    assert_receive {:memory_tracker_state_update, @issue_number, "rework"}, 2_000
    assert [digest] = AgentQueueStore.list_pending(updated.queue_store, @issue_number)
    assert digest.category == :coordination_event
    assert digest.body.events == [event]
    refute Enum.any?(AlertFeed.list(), &(&1["topic"] == "ticket.#{@issue_number}.agent.attention.dispatch-declined"))
  end

  test "an already-rework held worker gets a new review without a redundant transition or dispatch decline" do
    ticket = issue("rework")
    Application.put_env(:aiur, :memory_tracker_issues, [ticket])
    state = base_state(ticket)
    event = review_event(ticket)

    updated = CommentWake.maybe_reactivate_on_comment(state, @issue_number, :pr_review, event)

    refute_received {:memory_tracker_state_update, @issue_number, "rework"}
    assert [digest] = AgentQueueStore.list_pending(updated.queue_store, @issue_number)
    assert digest.body.events == [event]
    refute Enum.any?(AlertFeed.list(), &(&1["topic"] == "ticket.#{@issue_number}.agent.attention.dispatch-declined"))
  end

  # Regression guard: origin/main passes this; 3d2ea5c17 failed it. The cached
  # state can lag a handoff by one poll, so only a live worker may skip the write.
  test "regression guard: a finished worker cached as rework still moves a handed-off human-review ticket to rework" do
    Application.put_env(:aiur, :memory_tracker_issues, [issue("human-review")])
    state = base_state(issue("rework"), :completed)
    event = review_event(issue("human-review"))

    CommentWake.maybe_reactivate_on_comment(state, @issue_number, :pr_review, event)

    assert_receive {:memory_tracker_state_update, @issue_number, "rework"}, 2_000
  end
end
