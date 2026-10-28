defmodule Aiur.Conversation.JumpPointsTest do
  use ExUnit.Case, async: true
  alias Aiur.Conversation.JumpPoints
  alias Aiur.Events.Catalog

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
      full_topic = "ticket.6627." <> topic
      assert JumpPoints.kind_for(full_topic) == kind
      assert JumpPoints.entry(kind).kind in JumpPoints.kinds()
      assert Catalog.lookup(full_topic).owner != "unknown"
    end

    assert JumpPoints.kind_for("executor.progress") == "executor_progress"
    assert JumpPoints.kind_for("ticket.6627.agent.custom.unknown") == nil
    assert JumpPoints.kind_for("system.main.branch.push") == nil
  end

  test "catalogue metadata pins DESIGN-E4 defaults and semantic icons" do
    assert Enum.map(JumpPoints.kinds(), &JumpPoints.entry/1) == [
             %{kind: :progress, label: "Progress", icon: :chart_bar, default_visible: true, best_precision: :exact},
             %{kind: :phase, label: "Phase", icon: :flag, default_visible: false, best_precision: :exact},
             %{kind: :push, label: "Pushed", icon: :arrow_up_tray, default_visible: true, best_precision: :causal},
             %{kind: :pr_opened, label: "PR opened", icon: :code_bracket, default_visible: true, best_precision: :causal},
             %{kind: :pr_merged, label: "PR merged", icon: :code_bracket_square, default_visible: true, best_precision: :causal},
             %{kind: :ci, label: "CI result", icon: :check_circle, default_visible: false, best_precision: :observed},
             %{kind: :review_comment, label: "Review comment", icon: :chat_bubble_left, default_visible: false, best_precision: :observed},
             %{kind: :command_requested, label: "Command requested", icon: :question_mark_circle, default_visible: true, best_precision: :exact},
             %{kind: :command_resolved, label: "Command answered", icon: :check_circle, default_visible: true, best_precision: :exact},
             %{kind: :attention, label: "Attention", icon: :exclamation_triangle, default_visible: false, best_precision: :exact},
             %{kind: :executor_progress, label: "Executor progress", icon: :user, default_visible: false, best_precision: :causal}
           ]
  end

  test "unknown journal kinds and nil have non-raising fallbacks" do
    for kind <- ["future_jump_kind_from_journal", :unknown_jump_kind, nil] do
      assert JumpPoints.entry(kind) == nil
      assert JumpPoints.label(kind, %{}) == "Event"
    end
  end

  test "payload labels use identifiers and enums with bounded missing-field fallbacks" do
    assert JumpPoints.label(:push, %{sha: "3f9a1c012345"}) == "Pushed 3f9a1c0"
    assert JumpPoints.label("push", %{"sha" => "abcdef0123"}) == "Pushed abcdef0"
    assert JumpPoints.label(:push, %{}) == "Pushed"
    assert JumpPoints.label(:progress, %{percent: 60}) == "Progress 60%"
    assert JumpPoints.label(:progress, %{percent: "60"}) == "Progress"
    assert JumpPoints.label(:phase, %{phase: "work"}) == "Phase: work"
    assert JumpPoints.label(:phase, %{}) == "Phase"
    assert JumpPoints.label(:pr_opened, %{"pr" => %{"number" => 51}}) == "PR #51 opened"
    assert JumpPoints.label(:pr_merged, %{pr: %{number: 51}}) == "PR #51 merged"
    assert JumpPoints.label(:pr_opened, %{}) == "PR opened"
    assert JumpPoints.label(:pr_merged, %{pr: %{number: nil}}) == "PR merged"
    assert JumpPoints.label(:ci, %{topic: "ticket.1.ci.failed"}) == "CI failed"
    assert JumpPoints.label(:ci, %{topic: "ticket.1.ci.passed"}) == "CI passed"
    assert JumpPoints.label(:ci, %{}) == "CI result"
    assert JumpPoints.label(:review_comment, %{topic: "ticket.1.issue.commented", body: "private"}) == "Comment"
    assert JumpPoints.label(:review_comment, %{topic: "ticket.1.pr.review_comment", body: "private"}) == "Review comment"
    assert JumpPoints.label(:command_requested, %{text: "private"}) == "Command requested"
    assert JumpPoints.label(:command_resolved, %{text: "private"}) == "Command answered"
    assert JumpPoints.label(:attention, %{topic: "ticket.1.agent.blocked"}) == Aiur.AgentEventFeed.topic_label("ticket.1.agent.blocked")
    assert JumpPoints.label(:executor_progress, %{topic: "executor.run_started"}) == "Executor: Run started"
    assert JumpPoints.label(:executor_progress, %{topic: "executor." <> String.duplicate("é", 90)}) == "Executor: É" <> String.duplicate("é", 49)
    assert JumpPoints.label(:phase, %{phase: String.duplicate("x", 90)}) == "Phase: " <> String.duplicate("x", 53)
  end
end
