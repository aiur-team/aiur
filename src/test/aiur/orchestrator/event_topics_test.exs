defmodule Aiur.Orchestrator.EventTopicsTest do
  use ExUnit.Case, async: false

  alias Aiur.DecisionStore
  alias Aiur.Orchestrator.{EventTopics, Lifecycle, State}

  test "an answered Command wakes the idle dispatch poll for a stopped in-progress claim" do
    identifier = "answered-hold-#{System.unique_integer([:positive])}"
    topic = "ticket.#{identifier}.agent.decision.answered"

    decisions =
      for question <- ["Choose the implementation", "Confirm the acceptance"] do
        assert {:ok, %{decision: decision}} =
                 DecisionStore.request(%{"question" => question, "blocking" => true}, ticket: %{identifier: identifier}, source: %{agent_id: "event-test", session_id: "s", event_id: nil})

        decision
      end

    [first, second] = decisions

    answer = fn decision ->
      assert {:ok, %{status: status}} =
               DecisionStore.answer(
                 decision.decision_id,
                 %{"expected_version" => decision.version, "custom_response" => "Proceed", "idempotency_key" => decision.decision_id},
                 actor: %{kind: :operator, id: "event-test"}
               )

      assert status in [:accepted, :duplicate]
    end

    on_exit(fn -> Enum.each(decisions, answer) end)
    answer.(first)
    assert "ticket.*.agent.decision.answered" in Lifecycle.orchestrator_topics()

    now_ms = System.monotonic_time(:millisecond)
    timer_ref = Process.send_after(self(), :idle_poll, 60_000)

    state = %State{
      tick_timer_ref: timer_ref,
      tick_token: make_ref(),
      next_poll_due_at_ms: now_ms + 60_000,
      blocked_ticket_ids: MapSet.new([identifier]),
      claimed: MapSet.new(),
      running: %{},
      last_dispatch_poll_at_ms: now_ms - 30_000
    }

    try do
      woken = EventTopics.route(state, %{topic: topic})

      assert woken.next_poll_due_at_ms <= System.monotonic_time(:millisecond) + 1_000
      assert woken.tick_token != state.tick_token
      assert_receive {:tick, token} when token == woken.tick_token, 1_000
      # Another open Command still holds the ticket.
      assert MapSet.member?(woken.blocked_ticket_ids, identifier)
      answer.(second)
      released = EventTopics.route(woken, %{topic: topic})
      # Control calls must see the fresh local gate before the tracker poll runs.
      refute MapSet.member?(released.blocked_ticket_ids, identifier)
    after
      Process.cancel_timer(timer_ref)
    end
  end

  describe "classify_event_topic/1" do
    test "returns tagged identifiers for every supported topic shape" do
      assert EventTopics.classify_event_topic("ticket.42.pr.review_comment") ==
               {:pr_review_comment, "42"}

      assert EventTopics.classify_event_topic("ticket.42.issue.commented") ==
               {:issue_commented, "42"}

      assert EventTopics.classify_event_topic("ticket.42.pr.merged") == {:pr_merged, "42"}

      assert EventTopics.classify_event_topic("ticket.42.ci.failed") == {:ci_failed, "42"}
      assert EventTopics.classify_event_topic("ticket.42.ci.passed") == {:ci_passed, "42"}

      assert EventTopics.classify_event_topic("ticket.42.agent.pause.request") ==
               {:pause_request, "42"}

      assert EventTopics.classify_event_topic("ticket.42.agent.unblocked") ==
               {:agent_unblocked, "42"}

      assert EventTopics.classify_event_topic("ticket.42.branch.push") == {:branch_push, "42"}

      assert EventTopics.classify_event_topic("system.main.branch.push") ==
               {:system_branch_push, "main"}
    end

    test "returns nomatch for unknown topics" do
      assert EventTopics.classify_event_topic("ticket.42.unknown") == :nomatch
    end
  end

  describe "pr_merged_opts/1" do
    # #2609: the merged route needs the PR body, not just the merger — the
    # topic's ticket comes from the head branch, so only the body says whether
    # the merge closes the ticket or merely refs it.
    test "carries the merger login and the PR body off the event" do
      event = %{
        topic: "ticket.176.pr.merged",
        pr: %{"body" => "Refs #176 (merge does not close the ticket)", "merged_by" => %{"login" => "its-everdred"}}
      }

      assert EventTopics.pr_merged_opts(event) == [
               merged_by_login: "its-everdred",
               pr_body: "Refs #176 (merge does not close the ticket)"
             ]
    end

    test "reports a nil body and merger for an event carrying no pull request" do
      assert EventTopics.pr_merged_opts(%{topic: "ticket.176.pr.merged"}) == [
               merged_by_login: nil,
               pr_body: nil
             ]

      assert EventTopics.pr_merged_opts(%{topic: "ticket.176.pr.merged", pr: nil}) == [
               merged_by_login: nil,
               pr_body: nil
             ]
    end
  end

  describe "parsers" do
    test "reject prefixed and suffixed ticket topics" do
      parsers = [
        &EventTopics.parse_pr_review_comment_topic/1,
        &EventTopics.parse_issue_commented_topic/1,
        &EventTopics.parse_pr_merged_topic/1,
        &EventTopics.parse_ci_failed_topic/1,
        &EventTopics.parse_ci_passed_topic/1,
        &EventTopics.parse_pause_request_topic/1,
        &EventTopics.parse_agent_unblocked_topic/1,
        &EventTopics.parse_branch_push_topic/1
      ]

      for parser <- parsers do
        assert parser.("prefix.ticket.42.branch.push") == :nomatch
        assert parser.("ticket.42.branch.push.suffix") == :nomatch
      end
    end

    test "reject prefixed and suffixed system branch push topics" do
      assert EventTopics.parse_system_branch_push_topic("prefix.system.main.branch.push") == :nomatch
      assert EventTopics.parse_system_branch_push_topic("system.main.branch.push.suffix") == :nomatch
    end
  end
end
