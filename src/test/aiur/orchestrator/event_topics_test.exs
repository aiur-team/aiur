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

      assert EventTopics.classify_event_topic("ticket.42.branch.push") == {:branch_push, "42"}

      assert EventTopics.classify_event_topic("system.main.branch.push") ==
               {:system_branch_push, "main"}
    end

    test "returns nomatch for unknown topics" do
      assert EventTopics.classify_event_topic("ticket.42.unknown") == :nomatch
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
