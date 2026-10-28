defmodule Aiur.Conversation.JumpPointsTest do
  use ExUnit.Case, async: true
  alias Aiur.Conversation.JumpPoints

  test "catalogue topics resolve to the contract kinds" do
    for {topic, kind} <- [
          {"agent.progress", "progress"},
          {"agent.progress.checkin", "progress"},
          {"agent.progress.phase", "phase"},
          {"agent.phase.work.start", "phase"},
          {"branch.push", "push"},
          {"pr.opened", "pr_opened"},
          {"pr.merged", "pr_merged"},
          {"ci.passed", "ci"},
          {"ci.failed", "ci"},
          {"pr.review_comment", "review_comment"},
          {"issue.commented", "review_comment"},
          {"agent.decision.requested", "command_requested"},
          {"agent.decision.resolved", "command_resolved"},
          {"agent.attention.scope", "attention"},
          {"agent.blocked", "attention"}
        ] do
      assert JumpPoints.kind_for("ticket.6627." <> topic) == kind
    end

    assert JumpPoints.kind_for("executor.progress") == "executor_progress"
    assert JumpPoints.kind_for("ticket.6627.agent.custom.unknown") == nil
    assert JumpPoints.kind_for("system.main.branch.push") == nil
  end
end
