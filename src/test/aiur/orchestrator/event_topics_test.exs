defmodule Aiur.Orchestrator.EventTopicsTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.EventTopics

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
