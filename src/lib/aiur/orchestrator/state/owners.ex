defmodule Aiur.Orchestrator.State.Owners do
  @moduledoc """
  Field ownership within orchestration; readers may cross these boundaries.

  `:lifecycle` is the transition-owner placeholder until U2 resolves it.
  Listener fields remain here until their extraction. `codex_totals` and
  `codex_rate_limits` are dead fields retained for the later removal ticket.
  This table has no runtime callers.
  """

  @owners %{
    poll_interval_ms: :core,
    effective_poll_interval_ms: :core,
    idle_poll_backoff: :core,
    snapshot_key: :core,
    snapshot_generation: :core,
    next_poll_due_at_ms: :core,
    poll_check_in_progress: :core,
    poll_frozen: :core,
    tick_timer_ref: :core,
    tick_token: :core,
    initial_dispatch_cycle: :core,
    snapshot_ready?: :core,
    candidate_snapshot_fresh?: :core,
    poll_cycles_completed: :core,
    last_dispatch_poll_at_ms: :core,
    last_polled_issues: :core,
    running_issue_cache: :core,
    github_connectivity: :core,
    github_poll_delays: :core,
    queued_demand_hints: :core,
    waiting_for_human_episodes: :core,
    tracker_preflight_alert_signature: :core,
    tracker_preflight_alert_resolution_emitted: :core,
    human_review_observed_ids: :core,
    max_concurrent_agents: :dispatch,
    session_max_concurrent_agents: :dispatch,
    effective_concurrent_agents: :dispatch,
    load_envelope_state: :dispatch,
    capacity_hold: :dispatch,
    dispatch_hold: :dispatch,
    dispatch_capacity_constraints: :dispatch,
    dispatch_declines: :dispatch,
    dispatch_capacity_sample: :dispatch,
    capacity_starvation: :dispatch,
    fleet_capacity_starvation: :dispatch,
    capacity_starvation_resolution_emitted: :dispatch,
    fleet_capacity_starvation_resolution_emitted: :dispatch,
    todo_over_capacity_alert_active: :dispatch,
    prewarm_blocked_alert_active: :dispatch,
    prewarm_blocked_alert_resolution_emitted: :dispatch,
    prewarm_hold_ticks: :dispatch,
    prewarm_hold_since_ms: :dispatch,
    ci_readiness_checked: :dispatch,
    ci_readiness_unavailable_alerted: :dispatch,
    ci_readiness_check_pid: :dispatch,
    ci_readiness_check_token: :dispatch,
    ci_readiness_retry_at_ms: :dispatch,
    ci_readiness_scope: :dispatch,
    ci_readiness_result: :dispatch,
    blocked_ticket_ids: :dispatch,
    decision_store_unavailable_since_ms: :dispatch,
    decision_store_unavailable_alert_active: :dispatch,
    decision_store_unavailable_alert_resolution_emitted: :dispatch,
    dependency_circular_wait: :dispatch,
    observed_error_alerts: :dispatch,
    observed_error_alert_causes: :dispatch,
    active_attention_topics: :dispatch,
    dispatch_selection_hold: :dispatch,
    running: :lifecycle,
    claimed: :lifecycle,
    completed: :lifecycle,
    retry_attempts: :lifecycle,
    released_claims: :lifecycle,
    auto_resume: :lifecycle,
    model_fallback_waiting: :lifecycle,
    dispatch_recovery: :lifecycle,
    startup_claim_reconciliation_complete?: :lifecycle,
    startup_claim_reconciliation_failures: :lifecycle,
    orphaned_agent_reap_count: :lifecycle,
    contradictory_state_label_tickets: :lifecycle,
    contradictory_state_label_alert_active: :lifecycle,
    globally_paused: :control,
    global_pause: :control,
    control_lifecycle: :control,
    ci_lifecycle: :pr_lifecycle,
    last_ci_poll_started_at_ms: :pr_lifecycle,
    pr_review_seen_at: :pr_lifecycle,
    pr_ready_ledger: :pr_lifecycle,
    comment_rework_retries: :pr_lifecycle,
    rework_attempts: :pr_lifecycle,
    rework_attempt_alerted: :pr_lifecycle,
    merged_ticket_reconciliations: :pr_lifecycle,
    merged_ticket_reconciliation_failures: :pr_lifecycle,
    queue_store: :messaging,
    agent_totals: :accounting,
    agent_rate_limits: :accounting,
    codex_totals: :accounting,
    codex_rate_limits: :accounting,
    events_etag: :github_listeners,
    events_last_id: :github_listeners,
    firehose_partial_streak: :github_listeners,
    firehose_truncation_alert_active: :github_listeners,
    firehose_truncation_alert_resolution_emitted: :github_listeners,
    github_comments_since: :github_listeners,
    github_comment_etags: :github_listeners,
    github_comment_issue_updated_at: :github_listeners,
    github_comment_issue_list_cache: :github_listeners,
    github_comment_poll: :github_listeners,
    github_comment_reconcile_targets: :github_listeners,
    github_comment_reconcile_timer: :github_listeners,
    last_comment_poll_started_at_ms: :github_listeners,
    github_command_scan_since: :github_listeners
  }

  @members %{
    core: [Aiur.Orchestrator, Aiur.Orchestrator.IssueSync, Aiur.Orchestrator.TrackerHealth, Aiur.Orchestrator.SnapshotPublisher, Aiur.Orchestrator.SnapshotStore],
    dispatch: [Aiur.Orchestrator.Dispatcher, Aiur.Orchestrator.DispatchOutcome, Aiur.Orchestrator.DispatchPolicy, Aiur.Orchestrator.CapacityBinding, Aiur.Orchestrator.Slots],
    lifecycle: [
      Aiur.Orchestrator.Lifecycle,
      Aiur.Orchestrator.MembershipLifecycle,
      Aiur.Orchestrator.RetryEngine,
      Aiur.Orchestrator.Reconciler,
      Aiur.Orchestrator.AgentTeardown,
      Aiur.Orchestrator.AutoResume,
      Aiur.Orchestrator.StartupClaimReconciler,
      Aiur.Orchestrator.OrphanedWorkers,
      Aiur.Orchestrator.TrackedSet
    ],
    control: [Aiur.Orchestrator.PauseResume, Aiur.Orchestrator.GlobalPause, Aiur.Orchestrator.ControlLifecycle],
    pr_lifecycle: [
      Aiur.Orchestrator.CiLifecycle,
      Aiur.Orchestrator.CommentWake,
      Aiur.Orchestrator.ReworkGate,
      Aiur.Orchestrator.PRHealthScanner,
      Aiur.Orchestrator.ReadyForReviewTransitions,
      Aiur.Orchestrator.MergedTicketReconciler,
      Aiur.Orchestrator.ReworkRequeue
    ],
    messaging: [Aiur.Orchestrator.OperatorMessages, Aiur.Orchestrator.DigestCoalescer],
    accounting: [Aiur.Orchestrator.TokenAccounting],
    github_listeners: [Aiur.Orchestrator.CommentPolling, Aiur.Orchestrator.CommandScan, Aiur.Events.GithubFirehose, Aiur.Events.GithubCommentsPoller]
  }

  @spec owner(atom()) :: atom() | nil
  def owner(field), do: Map.get(@owners, field)

  @spec fields_of(atom()) :: [atom()]
  def fields_of(owner), do: for({field, ^owner} <- @owners, do: field)

  @doc "Owner module roots; nested modules belong too, except the umbrella Aiur.Orchestrator."
  @spec members_of(atom()) :: [module()]
  def members_of(owner), do: Map.get(@members, owner, [])
end
