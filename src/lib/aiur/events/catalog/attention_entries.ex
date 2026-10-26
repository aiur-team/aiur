defmodule Aiur.Events.Catalog.AttentionEntries do
  @moduledoc false

  # aiur:event-bus-boundary-member

  alias Aiur.Events.Catalog.Entry

  @alerts [
    # aiur/landing_watch/held_approval.ex
    {"ticket.*.agent.attention.approved_pr_not_armed_for_merge", "orchestration"},
    # aiur/orchestrator/retry_engine/hold_streak.ex
    {"ticket.*.agent.attention.budget-hold-persistent", "orchestration"},
    # aiur/orchestrator/comment_wake/dispatch.ex
    {"ticket.*.agent.attention.comment_wake_dispatch_declined", "orchestration"},
    # aiur/orchestrator/comment_wake/idle_rework.ex
    {"ticket.*.agent.attention.comment_wake_idle_issue", "orchestration"},
    # aiur/orchestrator/comment_wake/reactivation.ex
    {"ticket.*.agent.attention.comment_wake_inactive_issue", "orchestration"},
    # aiur/orchestrator/comment_wake/reactivation.ex
    {"ticket.*.agent.attention.comment_wake_inactive_issue_reactivation", "orchestration"},
    # aiur/orchestrator/comment_wake/reactivation.ex
    {"ticket.*.agent.attention.comment_wake_reactivation_refresh_failed", "orchestration"},
    # aiur/orchestrator/comment_wake/reactivation.ex
    {"ticket.*.agent.attention.comment_wake_reactivation_state_failed", "orchestration"},
    # aiur/landing_watch/conflict_routing.ex
    {"ticket.*.agent.attention.conflicting_held_pr", "orchestration"},
    # aiur/orchestrator/pause_resume/control_calls.ex
    {"ticket.*.agent.attention.control-call-crashed", "orchestration"},
    # aiur/orchestrator/issue_sync/dependencies.ex
    {"ticket.*.agent.attention.dependency-circular-wait", "orchestration"},
    # aiur/orchestrator/pause_resume/tracker_control.ex
    {"ticket.*.agent.attention.dispatch-budget-reset", "orchestration"},
    # aiur/orchestrator/pause_resume/tracker_control.ex
    {"ticket.*.agent.attention.dispatch-budget-reset.resolved", "orchestration"},
    # aiur/orchestrator/dispatcher/candidates.ex
    {"ticket.*.agent.attention.dispatch-declined", "orchestration"},
    # aiur/github/dispatch_authorization.ex
    {"ticket.*.agent.attention.dispatch_authorization.deferred", "github"},
    # aiur/decision_attention_resolution.ex
    {"ticket.*.agent.attention.duplicate-dispatch", "commands"},
    # aiur/orchestrator/dispatcher/budget_trip.ex
    {"ticket.*.agent.attention.error-lifetime_latch", "orchestration"},
    # aiur/orchestrator/retry_engine/exhaustion.ex
    {"ticket.*.agent.attention.error-retry_exhausted", "orchestration"},
    # aiur/orchestrator/retry_engine/exhaustion.ex
    {"ticket.*.agent.attention.error-state-write-failed", "orchestration"},
    # aiur/orchestrator/retry_engine/exhaustion.ex
    {"ticket.*.agent.attention.hosted-authentication-refused", "orchestration"},
    # aiur/orchestrator/review_landing_withdrawal.ex
    {"ticket.*.agent.attention.landing_withdrawal_failed", "orchestration"},
    # aiur/orchestrator/dispatcher/budget_trip.ex
    {"ticket.*.agent.attention.lifetime_latch_write_failed", "orchestration"},
    # aiur/orchestrator/comment_wake/merged_pr.ex
    {"ticket.*.agent.attention.merge_terminal_write_failed", "orchestration"},
    # aiur/orchestrator/merged_ticket_reconciler.ex
    {"ticket.*.agent.attention.merged_pr_reconciliation_failed", "orchestration"},
    # aiur/orchestrator/merged_ticket_reconciler/stranded_work.ex
    {"ticket.*.agent.attention.merged_with_stranded_work", "orchestration"},
    # aiur/agent_runner/model_label_refresh.ex
    {"ticket.*.agent.attention.model_label_unresolved", "agent-runner"},
    # aiur/agent_runner/rework_handoff_guard.ex
    {"ticket.*.agent.attention.no_op_rework", "orchestration"},
    # aiur/executor_attention/decision_escalation.ex
    {"ticket.*.agent.attention.operator-decision", "executor-attention"},
    # aiur/orchestrator/startup_claim_reconciler/release.ex
    {"ticket.*.agent.attention.orphan_release_comment_failed", "orchestration"},
    # aiur/orchestrator/parking.ex
    {"ticket.*.agent.attention.park_failed", "orchestration"},
    # aiur/orchestrator/duration_cap_release.ex
    {"ticket.*.agent.attention.paused-max_agent_duration", "orchestration"},
    # aiur/orchestrator/duration_cap_release.ex
    {"ticket.*.agent.attention.paused-max_agent_duration.resolved", "orchestration"},
    # aiur/orchestrator/comment_wake/reactivation.ex
    {"ticket.*.agent.attention.review_rework_refused", "orchestration"},
    # aiur/orchestrator/rework_gate.ex
    {"ticket.*.agent.attention.rework_attempt_limit", "orchestration"},
    # aiur/orchestrator/ci_lifecycle/approval_carry_alert.ex
    {"ticket.*.agent.attention.stale_approved_pr_head", "orchestration"},
    # aiur/orchestrator/startup_claim_reconciler.ex
    {"ticket.*.agent.attention.startup_claim_reconciliation_failed", "orchestration"},
    # aiur/orchestrator/startup_claim_reconciler.ex
    {"ticket.*.agent.attention.startup_orphan_claim_released", "orchestration"},
    # aiur/orchestrator/issue_sync/missing_labels.ex
    {"ticket.*.agent.attention.state-label-missing", "orchestration"},
    # aiur/orchestrator/issue_sync/missing_labels.ex
    {"ticket.*.agent.attention.state-label-missing-no-evidence", "orchestration"},
    # aiur/orchestrator/reconciler/divergence.ex
    {"ticket.*.agent.attention.state_divergence", "orchestration"},
    # aiur/orchestrator/issue_sync/stranded_tickets.ex
    {"ticket.*.agent.attention.stranded-requeue-failed", "orchestration"},
    # aiur/orchestrator/issue_sync.ex
    {"ticket.*.agent.attention.stranded-requeued", "orchestration"},
    # aiur/agent_resource_guard.ex
    {"ticket.*.agent.attention.synthetic-load", "agent-sandbox"},
    # aiur/orchestrator/ready_for_review_transitions.ex
    {"ticket.*.agent.attention.unreviewed_ready_pr", "orchestration"},
    # aiur/agent_runner/session_startup.ex
    {"ticket.*.agent.attention.unsupported_model", "agent-runner"},
    # aiur/orchestrator/status_report/human_wait.ex
    {"ticket.*.agent.attention.waiting_for_human", "orchestration"},
    # aiur/orchestrator/status_report/human_wait.ex
    {"ticket.*.agent.attention.waiting_for_human.resolved", "orchestration"}
  ]

  @spec entries() :: [Entry.t()]
  def entries do
    Enum.map(@alerts, fn {pattern, owner} -> Entry.alert(pattern, owner) end)
  end
end
