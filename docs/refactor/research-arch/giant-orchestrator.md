# Decomposition proposal: `src/lib/aiur/orchestrator.ex` (7,617 lines)

Target: behavior-preserving split of `Aiur.Orchestrator` into ~26 modules under
`src/lib/aiur/orchestrator/` (joining the existing `Aiur.Orchestrator.TrackedSet` at
`src/lib/aiur/orchestrator/tracked_set.ex`, 88 lines). All extractions are **plain
function moves executed inside the orchestrator GenServer process** — extracted modules
take `%Aiur.Orchestrator.State{}` (plus args) and return state or `{reply, state}`.
No new processes, no new GenServer call chains (house style: pure policy functions,
one dependency direction: `Aiur.Orchestrator` → `Aiur.Orchestrator.*` → `Aiur.*`).

---

## 1. Function / responsibility census

774 `def`/`defp` clauses. Grouped by concern (line ranges are the dominant home of each
group; a few helper clusters are interleaved and noted):

| # | Concern | Line ranges | ~LOC | Representative functions |
|---|---------|-------------|-----:|--------------------------|
| C1 | Module head: aliases, module attrs (retry delays, review states, `@pr_anchored_state`), `State` struct | 1–155 | 155 | `defmodule State` |
| C2 | GenServer lifecycle: `init/1` (cleanup ordering, tick seed), `terminate/2` (reap running agents, `drain: false`), topic subscriptions, tracked-set install/refresh | 156–308 | 150 | `init/1`, `terminate/2`, `subscribe_to_orchestrator_topics/0`, `install_event_tracked_fn/0`, `issue_tracked?/1`, `refresh_tracked_set/1` |
| C3 | `handle_info` fan-in: tick/poll-cycle loop (`tick_token` coalescing), `:DOWN`, worker runtime info, codex updates, control-state, retry timers, exchange events | 309–505 | 200 | `handle_info/2` clauses, `handle_agent_down/2` (506–549) |
| C4 | Event-topic parsing/classification (pure) | 550–608 | 60 | `parse_pr_review_comment_topic/1`, `parse_issue_commented_topic/1`, `parse_pr_merged_topic/1`, `parse_pause_request_topic/1`, `parse_branch_push_topic/1`, `parse_system_branch_push_topic/1`, `classify_event_topic/1` |
| C5 | Comment wake / rework routing: reactivate deactivated rows, idle→rework transition, comment-rework retry ladder, trust/benign filters, TOCTOU revalidation, `pr.merged` done | 609–631, 998–1326 | 400 | `maybe_reactivate_on_comment/5`, `reactivate_if_deactivated/5`, `maybe_transition_idle_issue_to_rework/5`, `schedule_comment_rework_retry/5`, `dispatch_reworked_comment_issue/2`, `transition_and_revalidate_comment_reactivation/5`, `revalidate_comment_reactivation/4`, `trusted_comment_event?/1`, `review_pass_comment?/1`, `mark_pr_merged_issue_done/2`, `transition_control_status/4` |
| C6 | PR-anchored work units (watched/commanded human PRs, sentinel state `pr-watch`): resolve/build/dispatch, stop-on-close, workspace cleanup | 632–776, 1678–1764 | 330 | `maybe_route_pr_anchored_or_legacy/5`, `resolve_pr_anchored_unit/2`, `build_pr_anchored_issue/3`, `dispatch_pr_anchored_unit/4`, `maybe_stop_closed_pr_anchored_agents/2`, `stop_closed_pr_anchored_entries/3`, `cleanup_pr_anchored_workspace/2` |
| C7 | Push/pause routing: `pause.request` handling, mark-sleeping, blocker `branch.push` auto-resume + `pending_auto_resume` stamping/drain, main-push agent notify (#720) | 777–997, 3013–3075 | 340 | `maybe_pause_on_request/2`, `maybe_mark_sleeping/2`, `maybe_resume_blockees_on_push/3`, `attempt_auto_resume/5`, `stamp_pending_auto_resume/4`, `reconcile_pending_auto_resumes/1`, `maybe_drain_pending_auto_resume/3`, `maybe_notify_agents_on_default_branch_push/3`, `subscribed_to_topic?/2` |
| C8 | GitHub polling drivers + comment-poll target selection: firehose, comments poll, running/human-review/watch targets, cursors, probe priorities, limits | 1327–1432, 1885–2183 | 420 | `poll_github_firehose/2`, `poll_github_comments/2`, `poll_github_comment_targets/5`, `github_comment_poll_targets/2`, `human_review_comment_poll_targets/2`, `watch_comment_poll_targets/2`, `merge_comment_cursors/2`, `human_review_pr_probe_priority/3`, `remember_polled_human_review_targets/3` |
| C9 | GitHub connectivity health: success/failure streaks, backoff normalization (`:escalate`), per-source poll delays, connectivity alert | 1434–1532 | 100 | `note_github_connectivity_success/2`, `note_github_connectivity_failure/3`, `normalize_github_backoff_ms/2`, `github_next_poll_delay_ms/1`, `next_poll_delay_ms/1`, `emit_github_connectivity_alert/1` |
| C10 | PR command scanning (`/aiur` commands on PRs): scan, annotate, cap hits per PR, cursor advance, command reactivation publish | 1533–1677, 1766–1883 | 260 | `scan_pr_commands/2`, `command_scan_review_comments/1`, `publish_command_hits/3`, `cap_command_pr_hits/2`, `publish_command_reactivation/3`, `advance_command_scan_since/2` |
| C11 | Dispatch pipeline top: `maybe_dispatch`, tracker preflight + error log clauses, prewarm gate, CPU load gate (#465/#477) | 2185–2394 | 210 | `maybe_dispatch/1`, `do_maybe_dispatch/1`, `ensure_tracker_preflight/1`, `log_tracker_preflight_error/1` (13 clauses), `dispatch_or_hold/2`, `maybe_choose_under_load/2`, `read_load/1`, `prewarm_gate/2`, `load_gate/3` |
| C12 | Test seam API (`*_for_test` thin wrappers) | 2425–2652 | 230 | `reconcile_issue_states_for_test/2`, `poll_github_comments_for_test/2`, `apply_stall_check_for_test/2`, … (~30 fns) |
| C13 | Reconciliation of polled states: per-issue active/terminal reconcile, reactivate-or-refresh, missing-id reconcile | 2395–2424, 2654–2696, 2835–2896 | 180 | `reconcile_running_lifecycle/1`, `refresh_running_issue_states/1`, `reconcile_running_issue_states/4`, `reconcile_issue_state/4`, `maybe_reactivate_or_refresh/2`, `reconcile_missing_running_issue_ids/3` |
| C14 | Human-review deactivation gate: verify PR exists before freeing slot, transient GraphQL error taxonomy, defer/reject | 2697–2833 | 140 | `maybe_deactivate_human_review_issue/2`, `verify_human_review_ready/1`, `transient_human_review_verification_error?/1`, `defer_human_review_transition/3`, `reject_human_review_transition/3` |
| C15 | Agent teardown: terminate vs deactivate running issue (slot-freeing, SSE stream close ordering, REPL kill, demonitor `:flush`) | 2817–2833, 2897–3011, 3260–3270, 6699–6721 | 220 | `terminate_running_issue/3`, `deactivate_running_issue/2`, `terminate_task/1`, `kill_repl_session/1`, `close_active_chat_streams/2`, `terminate_reason/1` |
| C16 | Runtime watchdogs: max-duration overrun pause (#420), stall restart, wedged-overcap termination | 3076–3271 | 200 | `reconcile_overrunning_agents/1`, `overrunning_entry?/3`, `maybe_pause_overrunning_entry/5`, `reconcile_stalled_running_issues/1`, `restart_stalled_issue/5`, `wedged_overcap_entry?/3`, `stall_elapsed_ms/2`, `last_activity_timestamp/1` |
| C17 | Polled-issue sync + dependency events: `last_polled_issues`, dependency add/remove/terminality events, task-state transition alerts, todo-capacity alert | 3272–3488, 6900–6953 | 340 | `sync_polled_issue_state/2`, `emit_dependency_transition_events/3`, `emit_task_state_transition_alert/3`, `maybe_enqueue_blocker_terminality_event/4`, `enqueue_dependency_event/4`, `sync_todo_capacity_alert/2`, `emit_todo_capacity_alert/2` |
| C18 | Dispatch selection policy (pure): choose loop, startup-todo alert schedule, priority sort, candidate/claim checks, per-state slot limits, active/terminal state sets | 3489–3723 | 240 | `choose_issues/2`, `maybe_schedule_startup_todo_alert/5`, `sort_issues_for_dispatch/1`, `should_dispatch_issue?/4`, `dispatch_candidate?/4`, `candidate_issue?/3`, `state_slots_available?/2`, `effective_state_limit/2`, `todo_issue_blocked_by_non_terminal?/2`, `terminal_state_set/0`, `active_state_set/0` |
| C19 | Dispatch execution: revalidate-then-dispatch, thrash budget breaker, worker-host spawn, running-entry seed | 3724–3904 | 180 | `dispatch_issue/4`, `do_dispatch_issue/4`, `dispatch_to_worker/4`, `check_thrash_budget/3`, `trip_thrash_breaker/2`, `reset_thrash_budget/2`, `spawn_issue_on_worker_host/5`, `revalidate_issue_for_dispatch/3` |
| C20 | Retry engine: schedule/cancel timers with `retry_token`, budget classification (`failure_retry?`), exhaustion → `error` state + claim release (#699), retry-poll failures, delay ladder, active-retry re-dispatch | 3906–4162, 4494–4595 | 460 | `schedule_issue_retry/4`, `complete_issue/2`, `failure_retry?/1`, `move_exhausted_issue_to_error_state/1`, `pop_retry_attempt_state/3`, `handle_retry_issue/4`, `handle_retry_poll_failure/5`, `handle_retry_issue_lookup/5`, `handle_active_retry/4`, `release_issue_claim/2`, `retry_delay/2`, `failure_retry_delay/1`, `pick_retry_*` |
| C21 | Workspace cleanup: startup todo-workspace cleanup, terminal-workspace cleanup, per-issue artifact cleanup, session-handle clear | 4163–4298 | 140 | `cleanup_issue_workspace/2`, `cleanup_terminal_issue_artifacts/2`, `run_startup_todo_workspace_cleanup/1`, `run_terminal_workspace_cleanup/1`, `cleanup_todo_workspaces_after_preflight/1`, `configured_todo_states/0` |
| C22 | Status / snapshot / dashboard: dashboard summaries, `:status` + `:snapshot` + `:poll_status` builders, idle statuses, backend/model labels | 4299–4493, 5238–5360 (call bodies) | 380 | `notify_dashboard/1`, `running_summaries/1`, `agent_statuses/1`, `running_status/4`, `idle_statuses/2`, `idle_status/2`, `entry_backend/1`, `entry_model/1`, `handle_call(:snapshot…)`, `next_poll_in_ms/2` |
| C23 | Worker-host + slot policy: host selection, per-host slots, max-agents cap (launch override, session override, adjust/set), active/paused counts, `available_slots` | 4596–4779 | 190 | `select_worker_host/2`, `least_loaded_worker_host/2`, `worker_slots_available?/2`, `worker_host_slots_available?/2`, `active_running_count/1`, `paused_running_count/1`, `launch_max_concurrent_agents_override/0`, `apply_session_max_concurrent_agents/2`, `max_concurrent_agent_limit/1`, `max_concurrent_agent_status/1`, `available_slots/1` |
| C24 | Public client API + `handle_call`/`handle_cast` routing: refresh, operator message, pause/resume/interrupt/pane-interrupt, RC toggle, max-agents, queue claim/consume/restore/fail, status/snapshot | 4780–5601, 6337–6362 | 620 | `request_refresh/1`, `send_operator_message/3`, `pause_agent/2`, `interrupt_agent/2`, `pane_interrupt/2`, `resume_agent/2`, `set_remote_control/3`, `claim_next_queue_item/2`, `snapshot/2`, `note_agent_activity/2`, ~35 `handle_call` clauses |
| C25 | Operator message / queue delivery: enqueue digests + operator messages, delivery-policy normalization, wake decisions, capabilities, queue depth | 5602–5981, 6474–6525 | 430 | `enqueue_event_digest_item/4`, `enqueue_operator_message/4`, `enqueue_for_running_entry/5`, `enqueue_after_reactivate/4`, `enqueue_after_resume/4`, `normalize_delivery_request/3`, `validate_operator_message/1`, `notify_running_queue_update/2`, `deliver_now?/2`, `trusted_comment_wake_required?/2`, `queue_wake_required?/1`, `no_active_turn?/1`, `issue_control_capabilities/2`, `accepted_delivery_policies/2`, `queue_depth_for_issue/2`, `pending_operator_messages_for_issue/2` |
| C26 | Pause / resume / reactivate implementation: resume gating (cap/state/host slots), operator-vs-automated clock semantics, pause-clock arithmetic, queued resume, control-status writes | 5983–6058, 6185–6473 | 420 | `resume_issue/2`, `reactivate_issue/2`, `do_reactivate/2`, `resume_paused_issue/3`, `send_resume_control_message/3`, `resume_queued_issue/2`, `pause_agent_reply/2`, `send_pause_control_message/2`, `put_running_control_status/3`, `reset_last_codex_timestamp/3`, `reset_duration_clock_if_capped/4`, `apply_pause_runtime_clock/4`, `thaw_pause_clock/4`, `shift_started_at_by_pause/2`, `maybe_emit_agent_control_alert/3`, `send_running_control_message/3` |
| C27 | Interrupts: interrupt reply, pane-interrupt decision table + actions | 6059–6184 | 130 | `interrupt_agent_reply/2`, `pane_interrupt_reply/2`, `perform_pane_interrupt/5`, `pane_interrupt_action/2`, `pane_interrupt_action_no_pane/2` |
| C28 | Remote-control mode: promote/demote to RC, redispatch teardown, label edit, RC trust, stray-server cleanup, RC summary | 6527–6747 | 220 | `set_remote_control_reply/3`, `promote_to_remote/2`, `demote_from_remote/2`, `teardown_for_redispatch/2`, `add_issue_label/2`, `remove_issue_label/2`, `remote_control_trust_opts/0`, `remote_control_summary/1`, `cleanup_stray_remote_control_servers/0` |
| C29 | Running-entry lookups + codex update integration | 4590–4595, 6363–6372, 6749–6839 | 120 | `find_running_by_identifier/2`, `find_running_key_by_identifier/2`, `find_running_by_repl_pane_id/2`, `find_issue_id_for_ref/2`, `integrate_codex_update/2`, `session_id_for_update/2`, `turn_count_for_update/3`, `maybe_put_runtime_value/3` |
| C30 | Scheduling/config plumbing: tick scheduling, poll-cycle start, pop entry, session completion totals, runtime-config refresh | 6840–6899 | 60 | `schedule_tick/2`, `schedule_poll_cycle_start/0`, `next_poll_in_ms/2`, `pop_running_entry/2`, `record_session_completion_totals/2`, `refresh_runtime_config/1` |
| C31 | Token / rate-limit accounting (mostly pure payload parsing) | 6972–7330 | 360 | `apply_agent_token_delta/2`, `apply_agent_rate_limits/2`, `apply_token_delta/2`, `extract_token_delta/2`, `compute_token_delta/4`, `extract_token_usage/1`, `extract_rate_limits/1`, `absolute_token_usage_from_payload/1`, `turn_completed_usage_from_payload/1`, `rate_limits_from_payload/1`, `rate_limits_map?/1`, `get_token_usage/2`, `payload_get/2`, `integer_like/1`, `running_seconds/2`, `effective_runtime_seconds/2` |
| C32 | Events-digest coalescing (pure; pinned by dedicated test) | 7331–7424 | 95 | `coalesce_events_digests/3`, `do_coalesce_events_digests/3`, `merge_events_digest_items/2`, `event_sort_key/1`, `event_dedupe_key/1`, `event_topic/1`, `event_comment_id/1` |
| C33 | Dependency auto-subscriptions + blocker-critical event classification | 7426–7616 | 190 | `auto_subscribe_for_dependency/2`, `auto_unsubscribe_for_dependency/2`, `subscribe_for_declared_blocker/2`, `default_blockee_subscriptions/1`, `default_blocker_subscriptions/1`, `attach_and_subscribe/3`, `direct_blockers_for/2`, `blocker_critical_digest?/2`, `blocker_critical_topic?/2` |

---

## 2. Proposed module split (NAME MAP — contract for downstream tickets)

All files under `src/lib/aiur/orchestrator/`. `Aiur.Orchestrator` remains the GenServer
facade in `src/lib/aiur/orchestrator.ex` (~550–700 residual lines): `init/terminate`,
`handle_info`/`handle_call`/`handle_cast` clause heads that delegate, the public client
API, the `*_for_test` seams (kept in place so no test file changes during extraction),
tick scheduling, and tracked-set sync (`issue_tracked?/1` stays here — the Publisher
closure contract). `Aiur.Orchestrator.TrackedSet` stays as-is.

Census keys (C-numbers) show what moves where.

| Module | File (under `src/lib/aiur/orchestrator/`) | Responsibility (one sentence) | ~LOC | Key functions moved |
|---|---|---|---:|---|
| `Aiur.Orchestrator.State` | `state.ex` | The orchestrator state struct plus running-entry field helpers: entry predicates (active/paused/sleeping/deactivated), entry lookups by identifier/ref/pane, runtime-value puts, counts, and pause-clock arithmetic. | ~300 | C1 `State` struct; C29 lookups; `active_running_count/1`, `paused_running_count/1`, `*_running_entry?/1`, `maybe_put_runtime_value/3`, `pop_running_entry/2`, `running_entry_session_id/1`, `issue_context/1`, `issue_tag/1`; C26 clock helpers `apply_pause_runtime_clock/4`, `thaw_pause_clock/4`, `shift_started_at_by_pause/2`, `running_seconds/2`, `effective_runtime_seconds/2` |
| `Aiur.Orchestrator.EventTopics` | `event_topics.ex` | Pure parsing/classification of exchange topics into routing tags. | ~90 | C4: `classify_event_topic/1`, all `parse_*_topic/1`, `tag_topic/2` |
| `Aiur.Orchestrator.DispatchPolicy` | `dispatch_policy.ex` | Pure dispatch admission policy: prewarm/load gates, candidate selection, priority sort, per-state slot limits, active/terminal state sets. | ~330 | C11 gates: `prewarm_gate/2`, `load_gate/3`, `read_load/1`; C18: `should_dispatch_issue?/4`, `dispatch_candidate?/4`, `candidate_issue?/3`, `sort_issues_for_dispatch/1`, `state_slots_available?/2`, `effective_state_limit/2`, `running_issue_count_for_state/2`, `todo_issue_blocked_by_non_terminal?/2`, `terminal_state_set/0`, `active_state_set/0`, `normalize_issue_state/1`, `state_slug/1`, `retry_candidate_issue?/2`, `issue_routable_to_worker?/1` |
| `Aiur.Orchestrator.Slots` | `slots.ex` | Worker-host selection and concurrency-cap accounting (max-agents launch/session/config precedence, per-host slots, available slots). | ~230 | C23: `select_worker_host/2`, `least_loaded_worker_host/2`, `running_worker_host_count/2`, `worker_slots_available?/2`, `worker_host_slots_available?/2`, `dispatch_slots_available?/2`, `resume_worker_slot_available?/2`, `launch_max_concurrent_agents_override/0`, `apply_session_max_concurrent_agents/2`, `max_concurrent_agent_limit/1`, `max_concurrent_agent_status/1`, `available_slots/1` |
| `Aiur.Orchestrator.Dispatcher` | `dispatcher.ex` | Dispatch execution: choose-loop over sorted candidates, pre-dispatch tracker revalidation, thrash-budget breaker, spawn on worker host, running-entry seeding. | ~370 | C19 all + C18 `choose_issues/2`, `maybe_schedule_startup_todo_alert/5`: `dispatch_issue/4`, `do_dispatch_issue/4`, `dispatch_to_worker/4`, `spawn_issue_on_worker_host/5`, `revalidate_issue_for_dispatch/3`, `check_thrash_budget/3`, `trip_thrash_breaker/2`, `reset_thrash_budget/2`, `default_running_control/1` |
| `Aiur.Orchestrator.RetryEngine` | `retry_engine.ex` | Retry scheduling and budget semantics, preserved verbatim: token-guarded timers, failure-vs-non-failure classification, exponential delays, retry-poll failures, exhaustion → `error` state + claim release, active-retry re-dispatch. | ~430 | C20 all: `schedule_issue_retry/4`, `retry_delay/2`, `failure_retry_delay/1`, `failure_retry?/1`, `pop_retry_attempt_state/3`, `handle_retry_issue/4`, `handle_retry_poll_failure/5`, `handle_retry_issue_lookup/5`, `handle_active_retry/4`, `release_issue_claim/2`, `complete_issue/2`, `move_exhausted_issue_to_error_state/1`, `emit_retry_poll_exhausted_alert/5`, `log_scheduled_retry/7`, `pick_retry_*`, `normalize_retry_*`, `next_retry_attempt_from_running/1` |
| `Aiur.Orchestrator.Reconciler` | `reconciler.ex` | Per-poll reconciliation of running entries against refreshed tracker states (active/terminal transitions, reactivate-or-refresh, missing-id handling). | ~250 | C13: `reconcile_running_lifecycle/1`, `refresh_running_issue_states/1`, `reconcile_running_issue_states/4`, `reconcile_issue_state/4`, `maybe_reactivate_or_refresh/2`, `reconcile_missing_running_issue_ids/3`, `refresh_running_issue_state/2`, `log_missing_running_issue/2` |
| `Aiur.Orchestrator.HumanReview` | `human_review.ex` | Human-review deactivation gate: verify the PR actually exists before freeing the slot; classify transient GitHub/GraphQL errors; defer or reject the transition. | ~210 | C14: `human_review_state?/1`, `maybe_deactivate_human_review_issue/2`, `verify_human_review_ready/1`, `verify_human_review_ready_with_tracker/1`, `transient_human_review_verification_error?/1`, `transient_github_graphql_error?/1`, `defer_human_review_transition/3`, `reject_human_review_transition/3`, `github_client_module/0` |
| `Aiur.Orchestrator.AgentTeardown` | `agent_teardown.ex` | Killing a running agent correctly: terminate vs deactivate (slot freed, row kept), SSE-stream close before brutal task kill, REPL pane/pid reap, demonitor flush. | ~230 | C15: `terminate_running_issue/3`, `deactivate_running_issue/2`, `terminate_task/1`, `kill_repl_session/1`, `close_active_chat_streams/2`, `terminate_reason/1` |
| `Aiur.Orchestrator.RuntimeWatchdog` | `runtime_watchdog.ex` | Per-tick safety checks on running agents: max-duration overrun pause, stall detection/restart, wedged-overcap termination. | ~240 | C16: `reconcile_overrunning_agents/1`, `overrunning_entry?/3`, `maybe_pause_overrunning_entry/5`, `reconcile_stalled_running_issues/1`, `restart_stalled_issue/5`, `maybe_restart_stalled_entry/5`, `wedged_overcap_entry?/3`, `terminate_wedged_overcap_entry/4`, `stall_elapsed_ms/2`, `last_activity_timestamp/1` |
| `Aiur.Orchestrator.CommentWake` | `comment_wake.ex` | Comment→wake/rework routing: reactivate deactivated rows on trusted comments, promote idle review-state tickets to rework, bounded comment-rework retries, TOCTOU revalidation, `pr.merged` completion. | ~400 | C5: `maybe_reactivate_on_comment/5`, `reactivate_if_deactivated/5`, `maybe_transition_idle_issue_to_rework/5`, `schedule_comment_rework_retry/5`, `seed_idle_comment_wake_event/3`, `dispatch_reworked_comment_issue/2`, `fetch_comment_dispatch_issue/1`, `transition_and_revalidate_comment_reactivation/5`, `transition_comment_issue_to_rework/3`, `revalidate_comment_reactivation/4`, `reactivate_current_issue/5`, `trusted_comment_event?/1`, `benign_review_pass_comment?/1`, `review_pass_comment?/1`, `comment_rework_retry_delay_ms/1`, `mark_pr_merged_issue_done/2`, `rework_issue_key/2`, `event_digest_summary/1`, `transition_control_status/4` |
| `Aiur.Orchestrator.PrAnchored` | `pr_anchored.ex` | Synthetic PR-anchored work units (`pr-watch` sentinel state): resolve/build/dispatch from PR comments and commands, stop agents when the PR closes, cleanup their workspaces. | ~330 | C6: `maybe_route_pr_anchored_or_legacy/5`, `pr_anchored_routing_enabled?/0`, `resolve_pr_anchored_unit/2`, `fetch_open_pull_request_for_routing/2`, `aiur_owned_head_ref?/2`, `build_pr_anchored_issue/3`, `pr_anchored_running_key/1`, `dispatch_pr_anchored_unit/4`, `pr_anchored_dispatch_fun/1`, `maybe_stop_closed_pr_anchored_agents/2`, `pr_anchored_running_entries/1`, `stop_closed_pr_anchored_entries/3`, `pr_open_state_fetcher/1`, `cleanup_pr_anchored_workspace/2`, `pr_field/2` |
| `Aiur.Orchestrator.PushRouting` | `push_routing.ex` | Routing of pause requests, sleep marks, blocker branch-push auto-resume (with capacity-deferred `pending_auto_resume` drain), and main-branch-push agent notification. | ~340 | C7: `maybe_pause_on_request/2`, `maybe_mark_sleeping/2`, `maybe_resume_blockees_on_push/3`, `maybe_resume_for_topic/4`, `attempt_auto_resume/5`, `stamp_pending_auto_resume/4`, `reconcile_pending_auto_resumes/1`, `maybe_drain_pending_auto_resume/3`, `clear_pending_auto_resume/2`, `subscribed_to_topic?/2`, `maybe_notify_agents_on_default_branch_push/3`, `default_branch_name/0` |
| `Aiur.Orchestrator.CommentPolling` | `comment_polling.ex` | GitHub firehose + comment polling drivers and poll-target selection (running, human-review, watched-PR targets), cursors and probe-priority ordering. | ~440 | C8: `poll_github_firehose/2`, `poll_github_comments/2`, `do_poll_github_comments/2`, `poll_github_comment_targets/5`, `github_comment_poll_targets/2`, `running_comment_poll_targets/1`, `human_review_comment_poll_targets/2`, `watch_comment_poll_targets/2`, `build_watch_targets/2`, `dedupe_*`, `with_human_review_pr_updated_at/2`, `human_review_pr_probe_priority/3`, `remember_polled_human_review_targets/3`, `merge_comment_cursors/2`, `all_comment_targets_failed?/2`, `normalize_comment_targets/1`, `put_open_pull_requests_by_target/2` |
| `Aiur.Orchestrator.TrackerHealth` | `tracker_health.ex` | Tracker/GitHub health gating: config+auth preflight with error logging, connectivity success/failure streaks, backoff normalization, per-source poll-delay map, connectivity alerts. | ~290 | C9 + C11 preflight: `ensure_tracker_preflight/1`, `ensure_github_auth_preflight/1`, `log_tracker_preflight_error/1`, `log_tracker_fetch_error/1`, `tracker_log_label/0`, `note_github_connectivity_success/2`, `note_github_connectivity_failure/3`, `connectivity_classification/1`, `connectivity_streak_count/2`, `normalize_github_backoff_ms/2`, `note_github_poll_interval/3`, `next_poll_delay_ms/1`, `github_next_poll_delay_ms/1`, `emit_github_connectivity_alert/1` |
| `Aiur.Orchestrator.CommandScan` | `command_scan.ex` | Scanning PR review/issue comments for `/aiur` commands, capping hits per PR, advancing the scan cursor, publishing command hits and reactivations. | ~330 | C10: `scan_pr_commands/2`, `do_scan_pr_commands/2`, `command_scan_review_comments/1`, `command_scan_issue_comments/1`, `command_scan_annotate/1`, `publish_command_hits/3`, `group_command_hits_by_pr/1`, `cap_command_pr_hits/2`, `publish_command_reactivation/3`, `command_scan_*` cursor/author/pr-number helpers, `advance_command_scan_since/2` |
| `Aiur.Orchestrator.IssueSync` | `issue_sync.ex` | Syncing polled issues into state and emitting derived events: dependency add/remove/terminality digests, task-state transition alerts, todo-over-capacity alert. | ~350 | C17: `sync_polled_issue_state/2`, `issues_by_id/1`, `emit_dependency_transition_events/3`, `emit_task_state_transition_alert/3`, `task_state_alert_*`, `blocker_map/1`, `blocker_terminal?/1`, `maybe_enqueue_blocker_terminality_event/4`, `enqueue_dependency_event/4`, `blocker_event_body/3`, `dependency_event_dedupe_key/3`, `dependency_causal_refs/2`, `dependency_subscription/2`, `sync_todo_capacity_alert/2`, `routable_todo_issues/1`, `emit_todo_capacity_alert/2` |
| `Aiur.Orchestrator.AutoSubscriptions` | `auto_subscriptions.ex` | Automatic pub/sub wiring for declared blocker/blockee dependencies and blocker-critical event classification. | ~210 | C33: `auto_subscribe_for_dependency/2`, `auto_unsubscribe_for_dependency/2`, `subscribe_for_declared_blocker/2`, `default_blockee_subscriptions/1`, `default_blocker_subscriptions/1`, `attach_and_subscribe/3`, `remove_auto_subscriptions/3`, `blockee_identifier_for/1`, `blocker_identifier_for/1`, `direct_blockers_for/2`, `blocker_critical_digest?/2`, `blocker_critical_event?/2`, `blocker_critical_topic?/2` |
| `Aiur.Orchestrator.OperatorMessages` | `operator_messages.ex` | Operator-message and event-digest enqueueing with delivery-policy normalization, wake decisions, and per-issue control capabilities/queue depth. | ~400 | C25: `enqueue_event_digest_item/4`, `enqueue_operator_message/4`, `enqueue_validated_operator_message/4`, `enqueue_for_running_entry/5`, `enqueue_after_reactivate/4`, `enqueue_after_resume/4`, `do_enqueue_running_operator_message/4`, `normalize_delivery_request/3`, `validate_operator_message/1`, `notify_running_queue_update/2`, `deliver_now?/2`, `event_digest_delivery_opts/2`, `trusted_comment_wake_required?/2`, `trusted_comment_event_digest?/1`, `comment_event_topic?/1`, `queue_wake_required?/1`, `no_active_turn?/1`, `issue_control_capabilities/2`, `accepted_delivery_policies/2`, `queue_depth_for_issue/2`, `pending_operator_messages_for_issue/2`, `operator_item_text/1`, `send_running_control_message/3`, `maybe_emit_agent_control_alert/3` |
| `Aiur.Orchestrator.DigestCoalescer` | `digest_coalescer.ex` | Pure coalescing of queued events-digest items: merge, order by event id, dedupe by topic+comment id. | ~120 | C32: `coalesce_events_digests/3`, `do_coalesce_events_digests/3`, `merge_events_digest_items/2`, `event_sort_key/1`, `event_dedupe_key/1`, `event_topic/1`, `event_comment_id/1` |
| `Aiur.Orchestrator.PauseResume` | `pause_resume.ex` | Pause/resume/reactivate state machine: resume admission (cap/state/host slots), operator-vs-automated duration-clock semantics, stall-clock reset on resume, queued resume, control-status writes. | ~400 | C26 (minus clock arithmetic in `State`): `resume_issue/2`, `reactivate_issue/2`, `do_reactivate/2`, `resume_paused_issue/3`, `send_resume_control_message/3`, `resume_queued_issue/2`, `pause_agent_reply/2`, `pause_running_or_inactive/3`, `send_pause_control_message/2`, `put_running_control_status/3`, `reset_last_codex_timestamp/3`, `reset_duration_clock_if_capped/4`, `maybe_reset_started_at/3` |
| `Aiur.Orchestrator.Interrupts` | `interrupts.ex` | Interrupt and pane-interrupt handling: pure action decision table plus the side-effecting reply paths. | ~190 | C27: `interrupt_agent_reply/2`, `pane_interrupt_reply/2`, `perform_pane_interrupt/5`, `pane_interrupt_action/2`, `pane_interrupt_action_no_pane/2` |
| `Aiur.Orchestrator.RemoteControlMode` | `remote_control_mode.ex` | Remote-control promotion/demotion of a running agent: RC label edits, redispatch teardown, RC trust, stray RC-server cleanup, RC summary. | ~260 | C28: `set_remote_control_reply/3`, `promote_to_remote/2`, `do_promote_to_remote/3`, `demote_from_remote/2`, `teardown_for_redispatch/2`, `add_issue_label/2`, `remove_issue_label/2`, `rc_log_context/1`, `remote_control_trust_opts/0`, `remote_control_summary/1`, `cleanup_stray_remote_control_servers/0` |
| `Aiur.Orchestrator.TokenAccounting` | `token_accounting.ex` | Codex-update integration and token/rate-limit accounting: per-entry deltas, session totals, and the pure payload parsers for usage/rate-limit shapes. | ~470 | C31 + C29 codex parts: `integrate_codex_update/2`, `codex_app_server_pid_for_update/2`, `session_id_for_update/2`, `turn_count_for_update/3`, `summarize_codex_update/1`, `apply_agent_token_delta/2`, `apply_agent_rate_limits/2`, `apply_token_delta/2`, `extract_token_delta/2`, `compute_token_delta/4`, `extract_token_usage/1`, `extract_rate_limits/1`, `absolute_token_usage_from_payload/1`, `turn_completed_usage_from_payload/1`, `rate_limits_from_payload/1`, `rate_limit_payloads/1`, `rate_limits_map?/1`, `explicit_map_at_paths/2`, `map_at_path/2`, `integer_token_map?/1`, `get_token_usage/2`, `payload_get/2`, `map_integer_value/2`, `integer_like/1`, `record_session_completion_totals/2` |
| `Aiur.Orchestrator.StatusReport` | `status_report.ex` | Read-only status surfaces: dashboard summaries, `:status`/`:snapshot`/`:poll_status` payload builders, idle statuses, backend/model labels. | ~380 | C22: `notify_dashboard/1`, `running_summaries/1`, `agent_statuses/1`, `running_statuses/2`, `running_status/4`, `idle_statuses/2`, `running_issue?/2`, `idle_status/2`, `idle_queue_depth/2`, `entry_backend/1`, `entry_model/1`, `issue_complexity/1`, snapshot/poll-status body builders, `next_poll_in_ms/2` |
| `Aiur.Orchestrator.WorkspaceCleanup` | `workspace_cleanup.ex` | Workspace/artifact janitor: startup todo-workspace cleanup, terminal-workspace cleanup, per-issue artifact + session-handle cleanup. | ~190 | C21: `cleanup_issue_workspace/2`, `cleanup_terminal_issue_artifacts/2`, `clear_session_handle/1`, `run_startup_todo_workspace_cleanup/1`, `cleanup_todo_workspaces_after_preflight/1`, `configured_todo_states/0`, `todo_issue_for_startup_cleanup?/1`, `run_terminal_workspace_cleanup/1`, `ensure_terminal_workspace_cleanup_preflight/1`, `cleanup_terminal_workspaces_after_preflight/1`, `log_terminal_workspace_cleanup_fetch_skip/1`, `cleanup_terminal_issue_workspace/1`, `cleanup_issue_workspace_for_issue/1` |

26 new modules + retained `Aiur.Orchestrator.TrackedSet` + residual `Aiur.Orchestrator`
facade. Two modules exceed the 200-line file norm with judgment: `RetryEngine` (~430,
kept whole because its semantics must be preserved verbatim and splitting the budget
accounting across files would hide the invariant) and `TokenAccounting` (~470, ~300 of
which is pure payload-shape parsing with zero state). `CommentPolling`, `CommentWake`,
`PauseResume`, `OperatorMessages` land ~400 as single cohesive state machines.

**Extraction mechanics (every wave):** moved `defp`s become `def`s on the new module
taking `%State{}` first; `Aiur.Orchestrator` keeps one-line delegating bodies for
everything referenced by its `handle_*` clauses, public API, or `*_for_test` seams.
Test files are NOT edited during extraction (the seams pin behavior); test moves are a
separate later cleanup. Module attributes move with their consumers (e.g.
`@comment_rework_max_attempts` → `CommentWake`, `@failure_retry_base_ms` → `RetryEngine`,
`@pr_anchored_state` → `PrAnchored` re-exported via function).

---

## 3. Extraction sequencing (waves; strictly serialized on this file)

Every wave: compiles, `mix test` green, ≤400 lines moved, one reviewable ticket.
Phase order: pure leaves → read-mostly helpers → lifecycle state machines →
history-hotspot cores last (after characterization tests land in W0).

- **W0 (tests only, no source move):** add characterization tests for the gaps in §4
  (retry engine, main-push notify, pending-auto-resume drain, thrash breaker,
  token-delta shapes). Prerequisite for phases C/D.

**Phase A — pure leaves (no timers/monitors/side effects):**
- **W1:** `State` — move nested `State` struct into `state.ex` (module name unchanged →
  zero call-site churn) + entry predicates/lookups/clock helpers (~300).
- **W2:** `EventTopics` + `DigestCoalescer` (~200 combined; both pure, digest pinned by
  `orchestrator_events_digest_coalesce_test.exs`).
- **W3:** `DispatchPolicy` (~330; `load_gate`/`prewarm_gate`/`read_load` stay callable
  as `Orchestrator.load_gate/3` etc. via defdelegate — pinned by
  `orchestrator_load_gate_test.exs`, `orchestrator_prewarm_gate_test.exs`).
- **W4:** `TokenAccounting` part 1 — pure payload parsers (~290).
- **W5:** `TokenAccounting` part 2 — delta computation + codex-update integration + totals (~180).
- **W6:** `Slots` (~230; pinned by `orchestrator_max_agents_test.exs`).
- **W7:** `TrackerHealth` (~290).
- **W8:** `WorkspaceCleanup` (~190; init ordering unchanged — see §4).

**Phase B — read-mostly / side-effecting helpers:**
- **W9:** `StatusReport` (~380; pinned by `orchestrator_status_test.exs`, 2,395 lines).
- **W10:** `CommentPolling` part 1 — target selection/cursor helpers (~290).
- **W11:** `CommentPolling` part 2 — firehose/comments poll drivers (~150; pinned by
  `orchestrator_firehose_test.exs` + `poll_github_comments_for_test` seams).
- **W12:** `CommandScan` (~330).
- **W13:** `IssueSync` (~350).
- **W14:** `AutoSubscriptions` (~210; pinned by `orchestrator_auto_subscribe_test.exs`).

**Phase C — lifecycle state machines:**
- **W15:** `AgentTeardown` (~230; pinned heavily by `orchestrator_deactivate_test.exs`, 4,736 lines).
- **W16:** `HumanReview` (~210).
- **W17:** `Reconciler` (~250).
- **W18:** `RuntimeWatchdog` (~240; pinned by `orchestrator_max_duration_test.exs`).
- **W19:** `PauseResume` (~400).
- **W20:** `Interrupts` (~190; pinned by `orchestrator_interrupt_test.exs`).
- **W21:** `RemoteControlMode` (~260; pinned by `orchestrator_remote_control_test.exs`).
- **W22:** `OperatorMessages` (~400; pinned by status/deactivate queue tests).

**Phase D — hotspot cores last (highest incident density, richest pins by then):**
- **W23:** `PushRouting` (~340).
- **W24:** `PrAnchored` (~330).
- **W25:** `CommentWake` (~400; hotspot #1 — do not batch with anything else).
- **W26:** `Dispatcher` (~370; includes thrash budget, pinned by `orchestrator_thrash_test.exs`).
- **W27:** `RetryEngine` part 1 — delays, `failure_retry?`, `pick_retry_*`, exhaustion path (~250).
- **W28:** `RetryEngine` part 2 — `handle_retry_*`, `pop_retry_attempt_state`,
  `handle_active_retry`, claim release wiring (~180).
- **W29 (optional cleanup):** slim the residual facade — collapse `*_for_test` seams to
  direct module calls in tests, split test files to match the new modules.

Rationale for ordering: waves W1–W8 prove the mechanical pattern on zero-risk code;
each later wave's moved code already depends only on previously-extracted modules
(one dependency direction, no cycles: e.g. `Dispatcher` uses `DispatchPolicy`+`Slots`
+`State`; `RetryEngine` uses `Dispatcher`; `CommentWake` uses `Dispatcher`+`AgentTeardown`).
Waves are strictly serialized — no two tickets touch `orchestrator.ex` concurrently.

---

## 4. Risks: semantics that must be preserved verbatim

Hotspot context: `docs/refactor/research-history-hotspots.md` ranks this file's seams
#1 (comment→wake/rework pipeline, ~35 incidents, the longest fix-of-fix chain
PR #621→#623→#629→#630→#632 plus the digest/TOCTOU chain #634→#642→#677→#682→#683) and
#6 (dispatch/lifecycle/retry budgets, ~15 incidents: retry budget burned by
non-failures, max-duration bound regression #420, load gate shipped disabled #477,
pause/resume races). It explicitly names this file's "comment wake/rework transitions,
dispatch gates (load, slots, claims), retry-budget accounting, max-duration bounds,
pause/resume/drain semantics" as refactor-caution zones.

### Concurrency / process invariants (apply to every wave)
1. **Single-process execution.** All extracted code must remain plain function calls
   executed inside the orchestrator GenServer. `Process.send_after(self(), …)` sites
   (`:tick` with `tick_token` ref, `{:retry_issue, id, retry_token}`,
   `{:retry_comment_rework, …}`, delayed `{:emit_system_alert, …}`),
   `Process.monitor/demonitor(…, [:flush])`, and `Process.cancel_timer` all assume
   `self()` is the orchestrator. Introducing any GenServer call from extracted code back
   into the orchestrator deadlocks (the `issue_tracked?/1` comment documents exactly this
   for the publish path — the Publisher closure must keep reading TrackedSet ETS directly).
2. **Token-guarded timers.** Stale-timer immunity comes from matching
   `{:retry_issue, id, retry_token}` against `retry_attempts[id].retry_token` and
   `{:tick, tick_token}` against `state.tick_token`. Preserve token creation/compare
   sites exactly; the old-timer `cancel_timer` before rescheduling prevents double-fires.
3. **Ordering inside `deactivate_running_issue`/`terminate_running_issue`:**
   close SSE chat streams BEFORE `terminate_task/1` (bridge streams otherwise stay
   subscribed 10 min); `kill_repl_session` before the task dies (brutal kill skips
   `after stop_session`); `refresh_tracked_set` immediately after deactivation (late
   codex events must not pass the publisher gate). Comments in-file mark each as load-bearing.
4. **`terminate/2`** must keep `ProcessReaper.reap([:agent], drain: false)` — `drain: true`
   would latch the reaper on supervised crash-restart and kill every agent the restarted
   orchestrator spawns. `init/1` ordering (terminal cleanup → todo cleanup → stray-RC
   cleanup → tracked-set init → subscriptions → tick 0) must not change.
5. **`do_reactivate` flips control to `:working` before dispatch** to prevent a
   double-claim race against a concurrent dispatch tick's slot count.

### Retry / reconciliation / cleanup semantics (preserve exactly — the mandate)
6. **Budget classification:** `failure_retry?/1` — `:continuation`, `:capacity_wait`,
   `:precondition` never burn `max_retry_attempts` (hotspot #6: budget burned by
   non-failures was a repeat incident class). Delay ladder: continuation/capacity 1s;
   precondition uses `retry_poll_failures`-indexed backoff; failures
   `10s * 2^(attempt-1)` capped by `max_retry_backoff_ms`.
7. **Claim lifecycle:** `claimed` is held across crash-retries and released only on
   exhaustion (#699) or terminal teardown; exhaustion also best-effort moves the ticket
   to `error` (`move_exhausted_issue_to_error_state`) and relies on the thrash breaker
   to bound re-dispatch thrash if that tracker write fails. `handle_agent_down`'s
   `:normal` path = complete + schedule `:continuation` attempt 1; crash path =
   `next_retry_attempt_from_running`.
8. **Load-gate scope:** admission-gate NEW work only; retries and reactivations bypass
   it deliberately (rescheduling under load would burn budget — #477's fix). `read_load`
   must not touch `/proc` when threshold disabled.
9. **Thrash breaker:** counted per (re)dispatch BEFORE workspace spawn cost; window reset
   on lapse; `reset_thrash_budget` on operator resume/reactivate is intentional.
10. **Comment-rework retries:** `@comment_rework_max_attempts 5` with backoff; transient
    GitHub errors must not consume the wake event (#631/#632); trusted-comment and
    benign review-pass filters; TOCTOU revalidation
    (`transition_and_revalidate_comment_reactivation`, #682-class).
11. **Pause/resume clocks:** operator resume resets `started_at` (fresh budget);
    automated/blocker resume preserves cumulative overrun (#420-class bound);
    `reset_last_codex_timestamp` on resume prevents the stall watchdog from killing a
    long-paused blockee on the next tick; `shift_started_at_by_pause` skips
    `:max_agent_duration`-paused entries. These live across `State` (clock arithmetic)
    and `PauseResume` (policy) — the W1/W19 split must not reorder any of the
    update steps in `send_resume_control_message`.
12. **Pending auto-resume drain:** publisher dedupes `(repo, ref, sha)` so a push event
    is consumed once; the `pending_auto_resume` hint + per-tick drain is the only path
    for a capacity-deferred blockee; hint cleared on non-paused/deactivated.
13. **Cleanup:** startup todo/terminal workspace cleanups run before the first tick and
    are preflight-gated; per-issue terminal artifact cleanup happens only on
    `cleanup_workspace: true` teardown; PR-anchored cleanup has its own path.

### Existing test pins (all in `src/test/aiur/`)
`orchestrator_deactivate_test.exs` (4,736 — reconcile/deactivate/human-review/comment-
rework/queue), `orchestrator_status_test.exs` (2,395 — snapshot/status/queue depth),
`orchestrator_max_duration_test.exs` (402 — overrun + clocks), `orchestrator_remote_control_test.exs`
(288), `orchestrator_interrupt_test.exs` (210), `orchestrator_firehose_test.exs` (184),
`orchestrator_events_digest_coalesce_test.exs` (132), `orchestrator_max_agents_test.exs`
(129), `orchestrator_auto_subscribe_test.exs` (89), `orchestrator_load_gate_test.exs` (73),
`orchestrator_thrash_test.exs` (44 — thin), `orchestrator_tracked_set_test.exs` (43),
`orchestrator_prewarm_gate_test.exs` (27), `orchestrator_broadcast_test.exs` (24); plus
`agent_runner_test.exs`, `core_test.exs`, `application_test.exs`, `live_e2e_test.exs`
touch the public API. Tests pin via the `*_for_test` seams and direct `handle_info`
sends — keep both stable through all waves.

### Characterization gaps (write in W0, before phases C/D)
- **Retry engine: no dedicated test file exists.** Nothing pins the `{:retry_issue, id, token}`
  stale-token drop, `:continuation` vs failure budget accounting, exponential
  delay/backoff cap, retry-poll-failure exhaustion, exhaustion → `error` state +
  claim release (#699), or `handle_active_retry`'s `:capacity_wait` reschedule. Highest-risk gap.
- **Main-push notify (#720):** only incidentally covered in deactivate tests; add a
  direct pin that active turns continue and standby agents are notified (not killed).
- **`pending_auto_resume` stamp/drain** (cap-full at push time → resumed when a slot frees).
- **Thrash breaker** (44-line test doesn't cover window lapse reset nor
  reset-on-operator-resume).
- **Token accounting payload shapes** (absolute vs turn-completed usage, rate-limit
  paths) — pure functions, cheap table tests.
- **PR-anchored close-stop + workspace cleanup**, **command-scan cursor advance**, and
  **connectivity backoff `:escalate` normalization** have no direct pins.
