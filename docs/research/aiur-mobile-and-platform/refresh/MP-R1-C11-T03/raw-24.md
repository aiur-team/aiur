| MP-R1-C5-T05 | — | — | "per touched file: each change is a one-line call rename; no file grows" | NO-LONGER-OVERSIZED |
| MP-R1-C5-T06 | — | — | "per touched file: one-line call renames; orchestrator files over 500 lines keep their U8 owners and must not grow" | NO-LONGER-OVERSIZED |
| MP-R1-C6-T03 | — | — | APP_BOOT | NO-LONGER-OVERSIZED |
| MP-R1-C6-T04 | — | — | CLI | NO-LONGER-OVERSIZED |
| MP-R1-C7-T01 | — | — | WORKSPACE (src/lib/aiur/workspace/provisioner.ex, 743 lines; U8 ledger at 465aca643 — re-resolve at ticket start against the then-current ledger, RC-23 / MP-R1-C11-T02); other touched files are under 500 lines | NO-LONGER-OVERSIZED |
| MP-R1-C7-T02 | — | — | CONFIG (src/lib/aiur/config.ex, ledger row `src/lib/aiur/config.ex,1462,CONFIG,Configuration,split,medium` at 465aca643; 1,471 lines at 45a290e3); TEST_HARNESS owns core_test.exs and extensions_test.exs. Re-resolve at ticket start against the then-current U8 ledger (RC-23, MP-R1-C11-T02) | NO-LONGER-OVERSIZED |
| MP-R1-C7-T03 | — | — | AGENT_CORE (agent_environment.ex 643, agent_process_log.ex 576); WORKSPACE (repo_base.ex 1,539, receives only delegates); other touched files < 500. Pinned to U8 ledger 465aca643; re-resolve at ticket start (RC-23, MP-R1-C11-T02) | NO-LONGER-OVERSIZED |
| MP-R1-C7-T04 | — | — | AGENT_CORE (agent_environment.ex 643, agent_process_log.ex 576; test agent_environment_test.exs 947); GH_GUARD (agent_github_guard.ex 541 — read only, not edited). Pinned to U8 ledger 465aca643; re-resolve at ticket start (RC-23, MP-R1-C11-T02) | NO-LONGER-OVERSIZED |
| MP-R1-C7-T05 | — | — | WORKSPACE (repo_base.ex 1,539; workspace/ownership/guardian.ex 819; workspace/provisioner.ex 743; tests repo_base_test.exs, ownership_test.exs, workspace_and_config_test.exs). Pinned to U8 ledger 465aca643; re-resolve at ticket start (RC-23, MP-R1-C11-T02) | NO-LONGER-OVERSIZED |
| MP-R1-C7-T06 | src/priv/github_budget.py | 1088 | GH_ACCESS (quota.ex, transport.ex 860, read_cache/*); GH_TRUST (issues.ex 1,248 — not edited); other edited files < 500. Pinned to U8 ledger 465aca643; re-resolve at ticket start (RC-23, MP-R1-C11-T02) | MISMATCH (ledger says GH_GUARD) |
| MP-R1-C7-T07 | — | — | LIFECYCLE_DISPATCH (orchestrator/dispatcher.ex 2,670 in ledger, 2,673 at base; dispatcher_test.exs 3,197). Pinned to U8 ledger 465aca643; re-resolve at ticket start (RC-23, MP-R1-C11-T02) | NO-LONGER-OVERSIZED |
| MP-R1-C7-T08 | — | — | LIFECYCLE_DISPATCH (orchestrator/dispatcher.ex 2,673 at base; dispatcher_test.exs 3,197); GH_ACCESS (github/ci_readiness.ex 1,149 — gains only @behaviour/@impl lines). Pinned to U8 ledger 465aca643; re-resolve at ticket start (RC-23, MP-R1-C11-T02) | NO-LONGER-OVERSIZED |
| MP-R1-C8-T01 | src/test/aiur_web/live/dashboard_live_test.exs | 4982 | DECISIONS (U8 ledger at 465aca643; re-resolve at ticket start per RC-23 / MP-R1-C11-T02; this ticket adds no lines to decision_store.ex) | MISMATCH (ledger says WEB) |
| MP-R1-C8-T02 | — | — | DECISIONS (decision_store.ex) and LIFECYCLE_DISPATCH (dispatcher.ex, operator_messages.ex) — U8 ledger at 465aca643; re-resolve at ticket start per RC-23 / MP-R1-C11-T02 | NO-LONGER-OVERSIZED |
| MP-R1-C8-T03 | — | — | WEB (units_row_test.exs, 597 lines pre-move at 45a290e3) — U8 ledger at 465aca643; re-resolve at ticket start per RC-23 / MP-R1-C11-T02. No moved production file is over 500 lines. | NO-LONGER-OVERSIZED |
| MP-R1-C8-T04 | — | — | LIFECYCLE_STATUS (open_ticket_source.ex 509, progress_retention.ex 532, ticket_activity/projection.ex 605 — reassigned only in the manifest, not edited) — U8 ledger at 465aca643; re-resolve at ticket start per RC-23 / MP-R1-C11-T02 | NO-LONGER-OVERSIZED |
| MP-R1-C8-T06 | src/test/aiur_web/live/dashboard_live_test.exs | 4982 | OPENCODE (live_conversation.ex 691, not edited), DECK_WEB (streamdeck_logs.ex 637; this ticket changes ≤4 lines) — U8 ledger at 465aca643; re-resolve at ticket start per RC-23 / MP-R1-C11-T02 | MISMATCH (ledger says WEB) |
| MP-R1-C8-T07 | — | — | GH_ACCESS (github/client.ex — confirm row) and BO_RUNTIME — U8 ledger at 465aca643; re-resolve at ticket start per RC-23 / MP-R1-C11-T02 | NO-LONGER-OVERSIZED |
| MP-R1-C8-T08 | — | — | BO_RUNTIME (graph_projection.ex 1,825, build_order_presenter.ex 1,046 — not edited) and APP_BOOT (src/lib/aiur.ex child order) — U8 ledger at 465aca643; re-resolve at ticket start per RC-23 / MP-R1-C11-T02 | NO-LONGER-OVERSIZED |
| MP-R1-C8-T09 | — | — | LIFECYCLE_DISPATCH (dispatch_policy.ex, issue_sync.ex — hooks preserved, not edited) — U8 ledger at 465aca643; re-resolve at ticket start per RC-23 / MP-R1-C11-T02. build_queue/ files are new in MP-E1 and must each be ≤500 lines. | NO-LONGER-OVERSIZED |
| MP-R1-C9-T01 | — | — | LIFECYCLE_DISPATCH (orchestrator/state.ex, orchestrator/dispatcher.ex, orchestrator/comment_polling.ex); EVENTS (tests under src/test/aiur/events/) | NO-LONGER-OVERSIZED |
| MP-R1-C9-T02 | — | — | LIFECYCLE_DISPATCH (orchestrator/comment_polling.ex, orchestrator/comment_polling/target_selection.ex, orchestrator/state.ex) | NO-LONGER-OVERSIZED |
| MP-R1-C9-T03 | — | — | LIFECYCLE_DISPATCH (orchestrator.ex, orchestrator/state.ex, orchestrator/lifecycle.ex, orchestrator/comment_polling*); EVENTS (events/github_webhook.ex tests) | NO-LONGER-OVERSIZED |
| MP-R1-C9-T04 | — | — | LIFECYCLE_DISPATCH (orchestrator/state.ex, orchestrator/dispatcher.ex); command_scan.ex (417 lines) is not in the U8 ledger -> n/a for that file | NO-LONGER-OVERSIZED |
| MP-R1-C9-T06 | — | — | LIFECYCLE_STATUS (src/test/aiur/orchestrator/rework_requeue_test.exs, 522 lines); rework_requeue.ex (459) not in the ledger | NO-LONGER-OVERSIZED |
| MP-R1-C9-T07 | — | — | LIFECYCLE_DISPATCH (orchestrator/state.ex, 1,033 lines at base) | NO-LONGER-OVERSIZED |
| MP-R1-C9-T08 | — | — | LIFECYCLE_DISPATCH (orchestrator.ex, issue_sync.ex, comment_wake.ex, comment_polling.ex, dispatcher.ex, state.ex); LIFECYCLE_STATUS (reconciler.ex, pause_resume.ex) | NO-LONGER-OVERSIZED |
| MP-R1-C9-T09 | — | — | LIFECYCLE_STATUS (reconciler.ex); LIFECYCLE_DISPATCH (orchestrator.ex, comment_wake.ex, operator_messages.ex, push_routing.ex); re-resolve at start | NO-LONGER-OVERSIZED |
| MP-R1-C9-T10 | — | — | CLI (src/lib/aiur/agent_control_cli.ex 3,362 lines in the ledger; 3,482 at 45a290e3; src/test/aiur/agent_control_cli_test.exs) | NO-LONGER-OVERSIZED |
| MP-R1-C9-T11 | — | — | CLI (agent_control_cli.ex, agent_control_cli_test.exs) | NO-LONGER-OVERSIZED |
| MP-R1-C9-T12 | — | — | CLI (agent_control_cli.ex, agent_control_cli_test.exs) | NO-LONGER-OVERSIZED |
| MP-R1-C9-T13 | — | — | CLI (agent_control_cli.ex, agent_control_cli_test.exs) | NO-LONGER-OVERSIZED |
| MP-R1-C9-T14 | — | — | CLI (agent_control_cli.ex, agent_control_cli_test.exs); LIFECYCLE_STATUS (orchestrator/status_report.ex, status_report_test.exs) | NO-LONGER-OVERSIZED |
| MP-R2-C2-T01 | — | — | EVENTS (subscription_store.ex, 748 lines at base; re-check at start per RC-23) | NO-LONGER-OVERSIZED |
| MP-R2-C2-T02 | — | — | EVENTS (sanitizer.ex 393 lines, under 500; re-check at start per RC-23) | NO-LONGER-OVERSIZED |
| MP-R2-C2-T03 | — | — | EVENTS (publisher.ex 539, subscription_store.ex 748); LIFECYCLE_STATUS (issue_log.ex 1049, not edited). Re-check at start per RC-23. | NO-LONGER-OVERSIZED |
| MP-R2-C2-T05 | — | — | EVENTS (publisher.ex 539, subscription_store.ex 748); re-check at start per RC-23 | NO-LONGER-OVERSIZED |
| MP-R2-C2-T06 | — | — | EVENTS (publisher.ex 539 lines; must shrink); re-check at start per RC-23 | NO-LONGER-OVERSIZED |
| MP-R2-C2-T08 | — | — | EVENTS (github_comments_poller.ex, github_firehose.ex, github_webhook.ex if > 500 at start); re-check per RC-23 | NO-LONGER-OVERSIZED |
| MP-R2-C2-T09 | — | — | ORC owners for ci_lifecycle.ex, pause_resume.ex, command_scan.ex (look up at start per RC-23); no file may grow | NO-LONGER-OVERSIZED |
| MP-R2-C2-T10 | — | — | DECISIONS (decision_store.ex 4826), EVENTS (executor_events.ex 525, alerts.ex 746); others < 500 at base. Re-check per RC-23; no file may grow. | NO-LONGER-OVERSIZED |
| MP-R2-C3-T01 | — | — | EVENTS (executor_events.ex 525 lines; must not grow); re-check at start per RC-23 | NO-LONGER-OVERSIZED |
| MP-R2-C3-T02 | — | — | EVENTS (executor_events.ex 525 lines; must shrink); re-check at start per RC-23 | NO-LONGER-OVERSIZED |
| MP-R2-C6-T01 | — | — | CONFIG (config.ex); current facade 440 lines, tracker_settings.ex owns accessors; new export schema in a small file | NO-LONGER-OVERSIZED |
| MP-R2-C6-T02 | — | — | APP_BOOT (aiur.ex); child_specs now application/children.ex (374 lines); new exporter files ≤ 300 lines | NO-LONGER-OVERSIZED |
| MP-R2-C7-T02 | — | — | DECK_WEB (streamdeck_channel.ex and channel tests); router/endpoint have no U8 release row; new files < 300 lines | NO-LONGER-OVERSIZED |
| MP-R2-C7-T04 | — | — | CLI (engine U8 row; agent_control_cli.ex has no current U8 row); current split paths audited in refresh report; keep files over 500 lines shrink-only | NO-LONGER-OVERSIZED |
| MP-R4-C1-T01 | — | — | DOCS (website/docs-app/apis/github.md, 760 lines at base) | NO-LONGER-OVERSIZED |
| MP-R5-C1-T01 | — | — | "DECK_WEB (streamdeck_channel.ex 609 lines): edit is a net-zero rename" | NO-LONGER-OVERSIZED |
| MP-R5-C1-T03 | — | — | "DECK_WEB (streamdeck_channel.ex 609, streamdeck_projection.ex 540): net-neutral or smaller" | NO-LONGER-OVERSIZED |
| MP-R5-C2-T01 | — | — | "WEB (dashboard_live.ex 2,903 lines): edit must be net-neutral" | NO-LONGER-OVERSIZED |
| MP-R6-C1-T01 | — | — | "DECK_WEB (streamdeck_logs.ex 637 lines): this ticket shrinks it" | NO-LONGER-OVERSIZED |
| MP-R6-C2-T01 | — | — | "DECK_WEB / DECK_PKG: only small edits, no file over 500 lines grows" | NO-LONGER-OVERSIZED |
| MP-R7-C2-T01 | — | — | "Aiur core / coding agent (registry data only; coding_agent.ex not edited)" | NO-LONGER-OVERSIZED |
| MP-R7-C2-T02 | — | — | "Aiur core / coding agent (backend.ex, 148 lines)" | NO-LONGER-OVERSIZED |
| MP-R7-C2-T03 | — | — | "Ticket lifecycle and dispatch (operator_messages/capabilities.ex, 125 lines)" | NO-LONGER-OVERSIZED |
| MP-R7-C3-T03 | — | — | AGENT_TURN (agent_runner/session_lifecycle.ex, 1,124 lines; split is U8's, not this ticket's) | NO-LONGER-OVERSIZED |
| MP-R7-C3-T06 | — | — | "src/lib/aiur/config.ex: U8 CONFIG owner (look up at the implementation SHA, RC-23)" | NO-LONGER-OVERSIZED |
| MP-R7-C4-T03 | — | — | AGENT_CORE (src/lib/aiur/coding_agent.ex, 1,179 lines) | NO-LONGER-OVERSIZED |
| MP-R7-C4-T04 | — | — | CLAUDE (remote_control.ex 726, telemetry.ex 666, coding_agent.ex 534); CODEX (event_humanizer.ex 510) | NO-LONGER-OVERSIZED |
| U0-T02 | packages/aiur-style/package-lock.json | 5175 | n/a | UNASSIGNED (>500, not in ledger — ask U0) |
| U0-T03 | — | — | "CI (.github/workflows/ci.yml, 750+ lines; add <= 4 lines)" | NO-LONGER-OVERSIZED |
| U1-T01 | — | — | "test files < 500 lines; no owner needed" | NO-LONGER-OVERSIZED |
| U1-T02 | — | — | "CLI (aiur-engine.sh 4,352 lines; no production growth expected; src/test/aiur_engine_stop_pidfile_test.exs 105 lines)" | NO-LONGER-OVERSIZED |
| U2-T01 | — | — | "LIFECYCLE_DISPATCH / LIFECYCLE_STATUS (call sites in issue_sync.ex 2,301, dispatcher.ex 2,686, pause_resume.ex 2,490, retry_engine.ex 1,557); CLI (agent_control_cli.ex). Each edit swaps a call or an injected default; growth of 0-2 lines per file, offset where the file is over 500." | NO-LONGER-OVERSIZED |
| U2-T02 | — | — | "LIFECYCLE_DISPATCH (issue_sync.ex 2,301; net change must be <= 0: the wrapper moves out)" | NO-LONGER-OVERSIZED |
| U2-T03 | — | — | "LIFECYCLE_DISPATCH (rate_limit_fallback.ex 763 at HEAD; net growth <= 0 - shrink by removing duplicated entry building); state.ex 1,037 (one new field, offset elsewhere)" | NO-LONGER-OVERSIZED |
| U2-T04 | — | — | "LIFECYCLE_STATUS (status_report.ex 1,489; growth must be offset - move reason building into waiting_reason.ex, < 500)" | NO-LONGER-OVERSIZED |
| U2-T05 | — | — | "WORKSPACE (guardian.ex 819; ownership_test.exs 1,243 - no net growth; add tests in a new file if needed)" | NO-LONGER-OVERSIZED |
| U3-T01 | — | — | "EVENTS (subscription_store.ex 748; net growth <= 0 - the inline drain replaces the self-send loop)" | NO-LONGER-OVERSIZED |
| U3-T02 | — | — | "under 500 (claims.ex 485 - keep under 500: net growth <= 15 lines)" | NO-LONGER-OVERSIZED |
| U3-T03 | — | — | "EVENTS (executor_wake_inbox.ex 619; net growth <= 0 - fold duplicated error paths)" | NO-LONGER-OVERSIZED |
| U4-T01 | — | — | "AGENT_TURN (queue_drain.ex 824, turn_loop.ex 591; net growth < 0 - two copies become one); LIFECYCLE_STATUS (pause_resume.ex, call-site only)" | NO-LONGER-OVERSIZED |
| U4-T02 | — | — | "AGENT_TURN (turn_loop.ex 591; net growth <= 0)" | NO-LONGER-OVERSIZED |
| U4-T03 | — | — | "CLAUDE (claude/coding_agent.ex 534; net growth <= 0 - reuse the Codex helper); startup_failure.ex < 200" | NO-LONGER-OVERSIZED |
| U5-T01 | — | — | "GH_ACCESS (transport.ex 860; net growth <= 5); comments.ex 233, pull_requests.ex small" | NO-LONGER-OVERSIZED |
| U5-T02 | — | — | "GH_TRUST (codeowners.ex 657 must shrink - delete its private fetchers and second grammar; code_owners.ex 487 must stay < 500)" | NO-LONGER-OVERSIZED |
| U5-T03 | — | — | "GH_ACCESS (resource_store.ex 2,261 - new function must be offset by removing the unconditional put; net growth <= 0); GH_TRUST (issues.ex 1,263, call-site only)" | NO-LONGER-OVERSIZED |
| U5-T04 | — | — | "GH_ACCESS (transport.ex 860, quota.ex 1,380 - no net growth: return shape only; review_threads/reply.ex < 500); DOCS (apis/github.md 779 - replace in place only)" | NO-LONGER-OVERSIZED |
| U6-T01 | — | — | "DECISIONS (decision_store.ex 4,826 - minimal edits, follow-up retry in a small new function; decision_log.ex stays < 500)" | NO-LONGER-OVERSIZED |
| U6-T02 | — | — | "DECISIONS (decision_store.ex 4,826 - minimal edits; decision_projection.ex < 500)" | NO-LONGER-OVERSIZED |
| U6-T03 | — | — | "under 500 (usage_aggregate/store.ex 335)" | NO-LONGER-OVERSIZED |
| U6-T04 | — | — | "LIFECYCLE_STATUS (status_report.ex 1,489), CLI (agent_control_cli.ex 3,362), WEB (presenter.ex 595) - no net growth per file; shared field list lives in status_report.ex" | NO-LONGER-OVERSIZED |
| U6-T05 | — | — | "WEB (analytics/presenter.ex 1,101 - no net growth); control_center_cache.ex < 500" | NO-LONGER-OVERSIZED |
| U7-T02 | — | — | "deletes linear/client.ex 599; touches config.ex and tracker.ex call sites only" | NO-LONGER-OVERSIZED |
| U9-T03 | — | — | "CI (.github/workflows/ci.yml 750+; add <= 6 lines)" | NO-LONGER-OVERSIZED |
| U8-P00-T01 | packages/aiur-style/package-lock.json | 5175 | "DECK_PKG, DOCS, SITE (lockfile rows) (ledger 465aca643; recount 58854d4c8)" | UNASSIGNED (>500, not in ledger — ask U0) |
| U8-P00-T01 | packages/streamdeck/package-lock.json | 3028 | "DECK_PKG, DOCS, SITE (lockfile rows) (ledger 465aca643; recount 58854d4c8)" | MISMATCH (ledger says DECK_PKG) |
| U8-P00-T01 | website/docs-app/bun.lock | 593 | "DECK_PKG, DOCS, SITE (lockfile rows) (ledger 465aca643; recount 58854d4c8)" | MISMATCH (ledger says DOCS) |
| U8-P00-T01 | website/package-lock.json | 1657 | "DECK_PKG, DOCS, SITE (lockfile rows) (ledger 465aca643; recount 58854d4c8)" | MISMATCH (ledger says SITE) |
| U8-P00-T02 | — | — | "all (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P01-T01 | — | — | "AGENT_CORE (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P01-T02 | — | — | "AGENT_CORE (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P02-T01 | — | — | "AGENT_TURN (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P02-T02 | — | — | "AGENT_TURN (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P03-T01 | src/test/fixtures/analytics/builds/test-build/build-summary.json | 1227 | "ANALYTICS (ledger 465aca643; recount 58854d4c8)" | MISMATCH (ledger says ANALYTICS) |
| U8-P03-T01 | src/test/fixtures/analytics/runs/boot-a/run-summary.json | 1042 | "ANALYTICS (ledger 465aca643; recount 58854d4c8)" | MISMATCH (ledger says ANALYTICS) |
| U8-P04-T01 | — | — | "APP_BOOT (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P05-T01 | — | — | "BO_DESIGN (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P06-T01 | — | — | "BO_PUBLISH (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P06-T02 | — | — | "BO_PUBLISH (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P07-T01 | — | — | "BO_RUNTIME (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P07-T02 | — | — | "BO_RUNTIME (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P07-T03 | — | — | "BO_RUNTIME (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P08-T01 | — | — | "BROWSER (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P08-T02 | — | — | "BROWSER (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P09-T01 | — | — | "BUILD_GATE (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P10-T01 | — | — | "CE (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P11-T01 | — | — | "CI (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P12-T01 | — | — | "CLAUDE (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P12-T02 | — | — | "CLAUDE (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P13-T01 | — | — | "CLI (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P13-T02 | — | — | "CLI (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P14-T01 | — | — | "CODEX (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P15-T01 | — | — | "CONFIG (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P15-T02 | — | — | "CONFIG (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P16-T01 | — | — | "DECISIONS (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P16-T02 | — | — | "DECISIONS (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P17-T01 | — | — | "DECK_DESIGN (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P18-T01 | — | — | "DECK_PKG (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P19-T01 | — | — | "DECK_WEB (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P19-T02 | — | — | "DECK_WEB (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P20-T01 | — | — | "DOCS (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P20-T02 | — | — | "DOCS (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P21-T01 | — | — | "EVENTS (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P21-T02 | — | — | "EVENTS (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P21-T03 | — | — | "EVENTS (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P22-T01 | — | — | "GH_ACCESS (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P22-T02 | src/priv/github_budget.py | 1088 | "GH_ACCESS (ledger 465aca643; recount 58854d4c8)" | MISMATCH (ledger says GH_GUARD) |
| U8-P22-T03 | — | — | "GH_ACCESS (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P22-T04 | — | — | "GH_ACCESS (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P23-T01 | — | — | "GH_GUARD (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P23-T02 | src/priv/github_budget.py | 1088 | "GH_GUARD (ledger 465aca643; recount 58854d4c8)" | MISMATCH (ledger says GH_GUARD) |
| U8-P24-T01 | src/lib/aiur/github/auth_preflight.ex | 549 | "GH_TRUST (ledger 465aca643; recount 58854d4c8)" | MISMATCH (ledger says GH_TRUST) |
| U8-P24-T01 | src/lib/aiur/github/config.ex | 506 | "GH_TRUST (ledger 465aca643; recount 58854d4c8)" | MISMATCH (ledger says GH_TRUST) |
| U8-P24-T01 | src/lib/aiur/github/dispatch_authorization.ex | 718 | "GH_TRUST (ledger 465aca643; recount 58854d4c8)" | MISMATCH (ledger says GH_TRUST) |
| U8-P24-T01 | src/lib/aiur/github/issues.ex | 1207 | "GH_TRUST (ledger 465aca643; recount 58854d4c8)" | MISMATCH (ledger says GH_TRUST) |
| U8-P25-T01 | — | — | "HIST_CE + HIST_PRODUCT (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P25-T02 | — | — | "HIST_CE (provisional, new row) (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P27-T01 | — | — | "LAYOUT (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P28-T01 | — | — | "LIFECYCLE_DISPATCH (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P28-T02 | — | — | "LIFECYCLE_DISPATCH (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P28-T03 | — | — | "LIFECYCLE_DISPATCH (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P28-T04 | — | — | "LIFECYCLE_DISPATCH (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P28-T05 | — | — | "LIFECYCLE_DISPATCH (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P28-T06 | — | — | "LIFECYCLE_DISPATCH (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P29-T01 | — | — | "LIFECYCLE_STATUS (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P29-T02 | — | — | "LIFECYCLE_STATUS (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P29-T03 | — | — | "LIFECYCLE_STATUS (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P29-T04 | — | — | "LIFECYCLE_STATUS (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P29-T05 | — | — | "LIFECYCLE_STATUS (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P29-T06 | — | — | "LIFECYCLE_STATUS (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P30-T01 | — | — | "LINEAR (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P31-T01 | — | — | "OPENCODE (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P31-T02 | — | — | "OPENCODE (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P32-T01 | — | — | "SITE (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P33-T01 | src/test/aiur/aiur_agent_skill_test.exs | 873 | "SKILLS (ledger 465aca643; recount 58854d4c8)" | MISMATCH (ledger says SKILLS) |
| U8-P34-T01 | — | — | "TELEMETRY (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P34-T02 | — | — | "TELEMETRY (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P35-T01 | — | — | "TEST_HARNESS (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P35-T02 | — | — | "TEST_HARNESS (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P36-T01 | src/test/aiur_web/live/dashboard_live_test.exs | 4982 | "WEB (ledger 465aca643; recount 58854d4c8)" | MISMATCH (ledger says WEB) |
| U8-P36-T02 | — | — | "WEB (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P36-T03 | src/lib/aiur_web/live/analytics_live.ex | 684 | "WEB (ledger 465aca643; recount 58854d4c8)" | MISMATCH (ledger says WEB) |
| U8-P36-T03 | src/lib/aiur_web/operator_control_center/analytics/charts.ex | 641 | "WEB (ledger 465aca643; recount 58854d4c8)" | MISMATCH (ledger says WEB) |
| U8-P36-T03 | src/lib/aiur_web/operator_control_center/analytics/presenter.ex | 1031 | "WEB (ledger 465aca643; recount 58854d4c8)" | MISMATCH (ledger says WEB) |
| U8-P36-T03 | src/test/aiur_web/live/analytics_live_test.exs | 1001 | "WEB (ledger 465aca643; recount 58854d4c8)" | MISMATCH (ledger says WEB) |
| U8-P37-T01 | — | — | "WORKSPACE (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P37-T02 | — | — | "WORKSPACE (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| U8-P37-T03 | — | — | "WORKSPACE (ledger 465aca643; recount 58854d4c8)" | NO-LONGER-OVERSIZED |
| MP-E1-C1-T01 | src/lib/aiur/github/issues.ex | 1207 | "GH_TRUST / GitHub access (github/issues.ex, 1248 lines; provisional, re-check per RC-23)" | MISMATCH (ledger says GH_TRUST) |
| MP-E1-C1-T02 | src/lib/aiur/github/issues.ex | 1207 | "LIFECYCLE_DISPATCH / Ticket lifecycle and dispatch (orchestrator/issue_sync.ex, 2295 lines; provisional, RC-23)" | MISMATCH (ledger says GH_TRUST) |
| MP-E1-C1-T03 | — | — | "GH_TRUST / GitHub access (github/issues.ex, 1248 lines; provisional, RC-23)" | NO-LONGER-OVERSIZED |
| MP-E1-C1-T04 | — | — | "GH_TRUST / GitHub access (github/issue_state.ex; provisional, RC-23)" | NO-LONGER-OVERSIZED |
| MP-E1-C1-T05 | — | — | "LIFECYCLE_DISPATCH / Ticket lifecycle and dispatch (orchestrator/dispatch_policy.ex, 1213 lines; provisional, RC-23)" | NO-LONGER-OVERSIZED |
| MP-E1-C1-T06 | — | — | "LIFECYCLE_DISPATCH / Ticket lifecycle and dispatch (orchestrator.ex, 1003 lines; provisional, RC-23)" | NO-LONGER-OVERSIZED |
| MP-E1-C3-T01 | — | — | "CONFIG / Configuration (config.ex 1462 lines, not edited); config/schema.ex small (provisional, RC-23)" | NO-LONGER-OVERSIZED |
| MP-E1-C3-T03 | — | — | "APP_BOOT / Repository support (src/lib/aiur.ex, 600 lines; provisional, RC-23)" | NO-LONGER-OVERSIZED |
| MP-E1-C3-T04 | — | — | "GH_TRUST (github/tracker.ex, small addition; provisional, RC-23)" | NO-LONGER-OVERSIZED |
| MP-E1-C3-T08 | — | — | "new file; one line in src/config/config.exs (composition root); provisional, RC-23" | NO-LONGER-OVERSIZED |
| MP-E1-C4-T03 | — | — | "GH_TRUST (github/tracker.ex small addition; provisional, RC-23)" | NO-LONGER-OVERSIZED |
| MP-E1-C4-T04 | src/lib/aiur/github/issues.ex | 1207 | "GH_TRUST (github/issues.ex 1248 lines, one-line change; provisional, RC-23)" | MISMATCH (ledger says GH_TRUST) |
| MP-E1-C4-T05 | — | — | "GH_TRUST (github/tracker.ex small addition; provisional, RC-23)" | NO-LONGER-OVERSIZED |
| MP-E1-C6-T01 | — | — | "CLI / npm CLI packaging (aiur-engine.sh 4224 lines) and Agent control CLI (agent_control_cli.ex 3362 lines); provisional, RC-23" | NO-LONGER-OVERSIZED |
| MP-E1-C6-T02 | — | — | "CLI (aiur-engine.sh, agent_control_cli.ex); provisional, RC-23" | NO-LONGER-OVERSIZED |
| MP-E1-C6-T03 | — | — | "CLI (aiur-engine.sh); provisional, RC-23" | NO-LONGER-OVERSIZED |
| MP-E1-C7-T01 | — | — | "APP_BOOT (src/lib/aiur.ex one child line); new file otherwise; provisional, RC-23" | NO-LONGER-OVERSIZED |
| MP-E2-C1-T01 | — | — | "DECISIONS (decision_store.ex 4,826; decision_projection.ex 1,039; decision_event.ex 1,057) — one delegating clause per file only" | NO-LONGER-OVERSIZED |
| MP-E2-C1-T02 | — | — | "DECISIONS (decision_validation.ex 494 — must stay ≤ 500; new logic in commands/request_content.ex)" | NO-LONGER-OVERSIZED |
| MP-E2-C1-T03 | — | — | "DECISIONS (decision_store.ex — two call sites replaced, no growth)" | NO-LONGER-OVERSIZED |
| MP-E2-C1-T04 | — | — | "DECISIONS (decision_api/public_projection.ex 114) + WEB (decision_presenter.ex 168); both stay small" | NO-LONGER-OVERSIZED |
| MP-E2-C2-T01 | — | — | "n/a — new module (≤ 200 lines)" | NO-LONGER-OVERSIZED |
| MP-E2-C2-T02 | — | — | "DECISIONS (decision_store.ex: one public fn + one handle_call; decision_event.ex / decision_projection.ex: list extension only)" | NO-LONGER-OVERSIZED |
| MP-E2-C2-T03 | — | — | "n/a for the new module; DECISIONS for the one-guard edit in decision_store.ex handle_defer" | NO-LONGER-OVERSIZED |
| MP-E2-C2-T04 | — | — | "CLI (aiur-engine.sh; agent_control_cli.ex 3,482 — 4-line delegator only) + DECISIONS (executor_command_cli.ex 387)" | NO-LONGER-OVERSIZED |
| MP-E2-C2-T05 | — | — | "DECISIONS (config/schema/decisions.ex 62; config.ex 1,471 — accessor lines only) + DOCS (configuration.md)" | NO-LONGER-OVERSIZED |
| MP-E2-C3-T01 | — | — | "DECISIONS (decision_store.ex — one guard call in handle_revision/4, actor_source in normalize_actor)" | NO-LONGER-OVERSIZED |
| MP-E2-C3-T02 | — | — | "n/a — new module; WEB untouched here (C3-T03 wires the dashboard)" | NO-LONGER-OVERSIZED |
| MP-E2-C3-T03 | src/test/aiur_web/live/dashboard_live_test.exs | 4982 | "WEB (decision_commands.ex 386; decision_action.ex 198; decision_revision_action.ex) — no file may pass 500" | MISMATCH (ledger says WEB) |
| MP-E2-C3-T04 | — | — | "WEB / DECK_WEB (streamdeck_channel.ex 609 — already over 500: net growth must be ≤ 0, move helpers out) + packages/streamdeck" | NO-LONGER-OVERSIZED |
| MP-E2-C4-T01 | — | — | "n/a — new module (≤ 200 lines)" | NO-LONGER-OVERSIZED |
| MP-E2-C4-T02 | — | — | "CODEX (codex/approvals.ex 356 — one call site); AGENT_CORE (app_server/turn_loop.ex 152); LIFECYCLE (runtime_watchdog.ex 376, token_accounting.ex) — guard lines only" | NO-LONGER-OVERSIZED |
| MP-E2-C4-T03 | — | — | "DECISIONS (decision_dispatch.ex 108); AGENT_CORE (checkpoint_delivery.ex 235, turn_callbacks.ex, app_server/interrupts.ex 76)" | NO-LONGER-OVERSIZED |
| MP-E2-C4-T04 | — | — | "AGENT_CORE (app_server/turn_loop.ex 152; app_server/interrupts.ex 76) — small guards; logic in commands/native_capture/release.ex" | NO-LONGER-OVERSIZED |
| MP-E2-C4-T05 | — | — | "CODEX (codex/config.ex 126; codex/app_server_port.ex 287)" | NO-LONGER-OVERSIZED |
| MP-E2-C5-T01 | — | — | "n/a — external repo its-everdred/claude-app-server (src/server.ts 42 KB; add a new module)" | NO-LONGER-OVERSIZED |
| MP-E2-C5-T02 | — | — | "CLAUDE (claude/coding_agent.ex 534 — already over 500: add one delegating clause, move ≥ equal lines out or coordinate with the U8 CLAUDE owner)" | NO-LONGER-OVERSIZED |
| MP-E2-C5-T03 | — | — | "n/a — logic in commands/native_capture/claude.ex and the sibling module" | NO-LONGER-OVERSIZED |
| MP-E2-C6-T01 | — | — | "CLI (aiur-engine.sh; agent_control_cli.ex 3,482 — delegator only); DECISIONS (one guard in decision_store.ex executor answer policy)" | NO-LONGER-OVERSIZED |
| MP-E2-C6-T02 | — | — | "U3 owner for executor_listener.ex / executor_wake_projection.ex (narrow allowlist only); DECISIONS (one dispatchability guard; decision.ex delivered?/1)" | NO-LONGER-OVERSIZED |
| MP-E2-C6-T03 | — | — | "CLI (asks_cli.ex, aiur-engine.sh run_asks)" | NO-LONGER-OVERSIZED |
| MP-E2-C6-T04 | — | — | "WEB (decision_inbox.ex 154; decision_card.ex 244; units_filters)" | NO-LONGER-OVERSIZED |
| MP-E2-C7-T01 | — | — | "WEB (decision_inbox.ex 154; overview.ex 173; fleet_table.ex 194; decision_card.ex 244)" | NO-LONGER-OVERSIZED |
| MP-E2-C7-T02 | — | — | "WEB (decision_detail.ex 164; decision_action.ex 198; history.ex 300) — new components for the timeline and the multi-question form" | NO-LONGER-OVERSIZED |
| MP-E2-C7-T03 | — | — | "WEB (units_table.ex 412; units_presenter.ex; units_policy.ex); LIFECYCLE (status_report.ex — one field)" | NO-LONGER-OVERSIZED |
| MP-E2-C7-T04 | — | — | "CLI (commands_cli.ex 246)" | NO-LONGER-OVERSIZED |
| MP-E2-C7-T05 | — | — | "WEB / DECK_WEB (streamdeck_commands.ex; streamdeck_channel.ex 609 — no net growth) + packages/streamdeck" | NO-LONGER-OVERSIZED |
| MP-E2-C8-T01 | — | — | "DOCS (concepts/commands.md 68; concepts/executor.md 32 — both small)" | NO-LONGER-OVERSIZED |
| MP-E2-C8-T02 | — | — | "DOCS (.claude/skills/aiur-run/SKILL.md 1,293 — already over 500: put new text in references/executor.md and link; net SKILL.md growth ≤ 5 lines)" | NO-LONGER-OVERSIZED |
| MP-E2-C8-T03 | — | — | "DOCS (.claude/skills/aiur-agent/attention-and-resolve.md, emit-and-subscribe.md); DECISIONS (one default literal)" | NO-LONGER-OVERSIZED |
| MP-E2-C8-T04 | — | — | "DECISIONS (config defaults) + DOCS" | NO-LONGER-OVERSIZED |
| MP-E3-C1-T02 | — | — | "U8 WEB owner (router.ex 361 lines; new controller and plug)" | NO-LONGER-OVERSIZED |
| MP-E3-C1-T03 | — | — | "U8 CLI owner (agent_control_cli.ex and aiur-engine.sh are large; add functions, do not restructure)" | NO-LONGER-OVERSIZED |
| MP-E3-C2-T01 | — | — | "n/a (new module; small option added to claude/transcript_tailer.ex, 260 lines)" | NO-LONGER-OVERSIZED |
| MP-E3-C4-T05 | — | — | "U8 CLI owner (agent_control_cli.ex)" | NO-LONGER-OVERSIZED |
| MP-E3-C6-T01 | — | — | "U8 WEB owner (new LiveView; dashboard_live.ex 2,903 lines must not grow beyond a nav link)" | NO-LONGER-OVERSIZED |
| MP-E3-C6-T02 | — | — | "U8 WEB owner" | NO-LONGER-OVERSIZED |
| MP-E3-C6-T03 | — | — | "U8 WEB owner" | NO-LONGER-OVERSIZED |
| MP-E3-C7-T01 | — | — | "U8 CLI owner" | NO-LONGER-OVERSIZED |
| MP-E4-C1-T03 | — | — | "U8 RUN owner (message_handler.ex 671 lines, session_lifecycle.ex: keep net additions small)" | NO-LONGER-OVERSIZED |
| MP-E4-C2-T02 | — | — | "U8 WEB owner (router.ex 361 lines)" | NO-LONGER-OVERSIZED |
| MP-E4-C4-T02 | — | — | "U8 WEB owner (decision_detail.ex 164 lines; no dashboard_live.ex growth)" | NO-LONGER-OVERSIZED |
| MP-E4-C5-T01 | — | — | "U8 WEB owner (new LiveView; dashboard_live.ex 2,903 lines must not grow)" | NO-LONGER-OVERSIZED |
| MP-E4-C5-T02 | — | — | "U8 WEB owner (new component module)" | NO-LONGER-OVERSIZED |
| MP-E4-C5-T03 | — | — | "U8 WEB owner" | NO-LONGER-OVERSIZED |
| MP-E4-C5-T04 | — | — | "U8 WEB owner (conversation_drawer.ex 276 lines; dashboard_live.ex must not grow beyond the link assign)" | NO-LONGER-OVERSIZED |
| MP-E4-C6-T01 | — | — | "U8 WEB owner (new component; no dashboard_live.ex growth)" | NO-LONGER-OVERSIZED |
| MP-E4-C6-T02 | — | — | "U8 WEB owner" | NO-LONGER-OVERSIZED |
| MP-E4-C7-T01 | — | — | "U8 SD owner (streamdeck_logs.ex 637 lines; this ticket reduces or keeps it)" | NO-LONGER-OVERSIZED |
| MP-E5-C1-T01 | — | — | WEB (conversation_drawer.ex is 276 lines; no split needed) | NO-LONGER-OVERSIZED |
| MP-E5-C1-T02 | — | — | BROWSER (conversation-voice-controller.js, 539 lines, over the 500-line U8 ceiling) | NO-LONGER-OVERSIZED |
| MP-E5-C1-T03 | — | — | BROWSER (layouts.ex is 336 lines; new hook file is small) | NO-LONGER-OVERSIZED |
| MP-E5-C2-T01 | — | — | WEB (voice_channel.ex is 331 lines; target validation goes to a new module) | NO-LONGER-OVERSIZED |
| MP-E5-C2-T02 | — | — | WEB (voice_channel.ex) | NO-LONGER-OVERSIZED |
| MP-E5-C2-T03 | — | — | WEB (dashboard_live.ex 2,903 lines — the change is net-neutral: one assign line; logic lives in a new module) | NO-LONGER-OVERSIZED |
| MP-E5-C3-T01 | — | — | BROWSER (controller), WEB (component) | NO-LONGER-OVERSIZED |
| MP-E5-C3-T02 | — | — | WEB | NO-LONGER-OVERSIZED |
| MP-E5-C3-T03 | — | — | BROWSER (controller), WEB (voice_channel.ex) | NO-LONGER-OVERSIZED |
| MP-E5-C4-T01 | — | — | WEB (decision_action.ex is 198 lines) | NO-LONGER-OVERSIZED |
| MP-E5-C4-T02 | — | — | WEB (decision_revision_action.ex) | NO-LONGER-OVERSIZED |
| MP-E5-C5-T01 | — | — | WEB (agent_log_modal.ex is 181 lines) | NO-LONGER-OVERSIZED |
| MP-E5-C6-T01 | — | — | BROWSER (conversation-voice-controller.js after the C1-T02 split) | NO-LONGER-OVERSIZED |
| MP-E5-C6-T02 | — | — | BROWSER | NO-LONGER-OVERSIZED |
| MP-E5-C6-T03 | — | — | WEB | NO-LONGER-OVERSIZED |
| MP-E5-C8-T01 | — | — | WEB (router.ex, endpoint.ex; new modules are small) | NO-LONGER-OVERSIZED |
| MP-E5-C8-T02 | — | — | WEB (voice_channel.ex) | NO-LONGER-OVERSIZED |
| MP-E6-C11-T05 | — | — | harness adapter files per MP-R7 (each adapter + one new fork_replay.ex) | NO-LONGER-OVERSIZED |
| MP-E6-C3-T02 | — | — | launcher (aiur-engine.sh, 4,260 lines — add one dispatch case and one small cmd function) | NO-LONGER-OVERSIZED |
| MP-E6-C6-T03 | — | — | launcher (aiur-engine.sh — one subcommand in cmd_voice) | NO-LONGER-OVERSIZED |
| MP-E6-C7-T04 | — | — | BROWSER | NO-LONGER-OVERSIZED |
| MP-E7-C2-T03 | — | — | LIFECYCLE_DISPATCH (orchestrator.ex 1,003 lines: +6 lines of delegating handle_call clauses only; logic in a new module) | NO-LONGER-OVERSIZED |
| MP-E7-C2-T04 | — | — | LIFECYCLE_DISPATCH (orchestrator/state.ex 1,033 lines: one call added in put_session_execution/4; logic in orchestrator/listener_modes.ex) | NO-LONGER-OVERSIZED |
| MP-E7-C3-T01 | — | — | AGENT_TURN (agent_queue_store.ex, 597 lines: ≤ 25 added lines, no new responsibilities; agent_queue.ex 54 lines) | NO-LONGER-OVERSIZED |
| MP-E7-C3-T02 | — | — | LIFECYCLE_DISPATCH (operator_messages.ex 1,167 lines: ≤ 20 lines — the :listener branch and the checkpoint-matcher exclusion; delivery_policy.ex 186 lines) | NO-LONGER-OVERSIZED |
| MP-E7-C4-T02 | — | — | AGENT_TURN (app_server/*), CODEX (codex/*) | NO-LONGER-OVERSIZED |
| MP-E7-C4-T03 | — | — | AGENT_TURN (muse/* has no dedicated U8 owner; files are < 500 lines) | NO-LONGER-OVERSIZED |
| MP-E7-C4-T04 | — | — | CLAUDE | NO-LONGER-OVERSIZED |
| MP-E7-C5-T01 | — | — | AGENT_CORE (agent tool surface) | NO-LONGER-OVERSIZED |
| MP-E7-C5-T02 | — | — | ORCH (operator_messages/*) | NO-LONGER-OVERSIZED |
| MP-E7-C5-T03 | — | — | ORCH | NO-LONGER-OVERSIZED |
| MP-E7-C5-T04 | — | — | AGENT_TURN (turn prompt) | NO-LONGER-OVERSIZED |
| MP-E7-C6-T01 | — | — | WEB (observability_api_controller is oversized — new controller module) | NO-LONGER-OVERSIZED |
| MP-E7-C6-T02 | — | — | CLAUDE (hook command generation) | NO-LONGER-OVERSIZED |
| MP-E7-C6-T03 | — | — | EXE (executor attach CLI, MP-E3 owner) | NO-LONGER-OVERSIZED |
| MP-E7-C7-T01 | src/test/aiur_web/live/dashboard_live_test.exs | 4982 | WEB (dashboard_live.ex is 2,903 lines — new component module only) | MISMATCH (ledger says WEB) |
| MP-E7-C7-T02 | — | — | TUI (agent_list/*) | NO-LONGER-OVERSIZED |
| MP-E7-C7-T03 | — | — | CTL (agent_control_cli.ex is 3,482 lines — new module only) | NO-LONGER-OVERSIZED |
| MP-E7-C7-T04 | — | — | MSG | NO-LONGER-OVERSIZED |
| MP-E8-C13-T01 | src/lib/aiur/github/issues.ex | 1207 |  | MISMATCH (ledger says GH_TRUST) |
| MP-E8-C13-T04 | src/lib/aiur/github/issues.ex | 1207 |  | MISMATCH (ledger says GH_TRUST) |
| MP-E8-C2-T03 | website/public/assets/aiur-logo.png | 2097 |  | UNASSIGNED (>500, not in ledger — ask U0) |
| MP-E8-C3-T03 | src/test/fixtures/build_home/design-source/assets/build.js | 1577 |  | UNASSIGNED (>500, not in ledger — ask U0) |
| MP-E8-C4-T03 | src/lib/aiur/github/issues.ex | 1207 |  | MISMATCH (ledger says GH_TRUST) |
| MP-E8-C5-T02 | src/lib/aiur/github/issues.ex | 1207 |  | MISMATCH (ledger says GH_TRUST) |
| MP-E8-C5-T03 | src/lib/aiur/github/issues.ex | 1207 |  | MISMATCH (ledger says GH_TRUST) |
| MP-E8-C5-T04 | src/test/aiur/aiur_agent_skill_test.exs | 873 |  | MISMATCH (ledger says SKILLS) |
| MP-E8-C6-T02 | src/lib/aiur/github/issues.ex | 1207 |  | MISMATCH (ledger says GH_TRUST) |
| MP-E8-C8-T01 | src/test/fixtures/build_home/design-source/assets/build.js | 1577 |  | UNASSIGNED (>500, not in ledger — ask U0) |
| MP-E8-C8-T04 | src/lib/aiur/github/config.ex | 506 |  | MISMATCH (ledger says GH_TRUST) |
| MP-N1-C1-T01 | packages/streamdeck/package-lock.json | 3028 | n/a (new package; no U8 ledger row) | MISMATCH (ledger says DECK_PKG) |
| MP-N1-C4-T04 | — | — | "U8 ledger owner of src/lib/aiur_web/components/layouts.ex (U6 scope src/lib/aiur_web/)" | NO-LONGER-OVERSIZED |
| MP-N2-C10-T01 | — | — | "WEB (U8 ledger; look up the owner of http_server.ex and router.ex at the implementation SHA)" | NO-LONGER-OVERSIZED |
| MP-N2-C10-T02 | — | — | "n/a (new gateway modules); launcher lines in aiur-engine.sh are shared with U1/U9 — recheck at the implementation SHA" | NO-LONGER-OVERSIZED |
| MP-N2-C10-T03 | — | — | "launcher dispatch in aiur-engine.sh (U1/U9 share the file; recheck lines at the implementation SHA)" | NO-LONGER-OVERSIZED |
| MP-N2-C10-T04 | — | — | "WEB (endpoint.ex); look up at the implementation SHA" | NO-LONGER-OVERSIZED |
| MP-N2-C2-T01 | — | — | "aiur.ex child list (U8 ledger owner of src/lib/aiur.ex; look up at the implementation SHA)" | NO-LONGER-OVERSIZED |
| MP-N2-C2-T02 | — | — | "shutdown.ex (U8 ledger owner; look up at the implementation SHA)" | NO-LONGER-OVERSIZED |
| MP-N2-C3-T02 | — | — | "aiur-engine.sh and cli.ex (U1/U9 share the engine; look up owners at the implementation SHA)" | NO-LONGER-OVERSIZED |
| MP-N2-C3-T04 | — | — | "init.ex (INI; look up at the implementation SHA)" | NO-LONGER-OVERSIZED |
| MP-N2-C4-T01 | — | — | "cli.ex (U8 ledger owner; look up at the implementation SHA); new modules n/a" | NO-LONGER-OVERSIZED |
| MP-N2-C4-T02 | — | — | "aiur-engine.sh (shared with U1/U9; recheck line numbers at the implementation SHA)" | NO-LONGER-OVERSIZED |
| MP-N2-C5-T01 | — | — | "n/a (new modules under src/lib/aiur/machine/); launcher dispatch lines shared with U1/U9 — recheck at the implementation SHA" | NO-LONGER-OVERSIZED |
| MP-N2-C6-T01 | — | — | "WEB — router.ex is in the U8 ledger (MP-N2-C6 named there); look up the owner at the implementation SHA" | NO-LONGER-OVERSIZED |
| MP-N2-C6-T02 | — | — | "WEB — financial_data_access.ex / proof.ex / router.ex; look up U8 owners at the implementation SHA" | NO-LONGER-OVERSIZED |
| MP-N2-C6-T03 | — | — | "WEB — router.ex (U8 ledger); look up at the implementation SHA" | NO-LONGER-OVERSIZED |
| MP-N2-C7-T01 | — | — | "n/a (new modules); engine dispatch lines shared with U1/U9" | NO-LONGER-OVERSIZED |
| MP-N2-C8-T02 | — | — | "WEB — router.ex and a new LiveView module (do not grow dashboard_live.ex, 2,903 lines, per U8)" | NO-LONGER-OVERSIZED |
| MP-N2-C9-T01 | — | — | "SITE/DOCS (U8 ledger)" | NO-LONGER-OVERSIZED |
| MP-N3-C1-T01 | — | — | "n/a (new module; PRJ boundary owner per U8 ledger at implementation time)" | NO-LONGER-OVERSIZED |
| MP-N3-C1-T02 | — | — | "n/a (new provider module)" | NO-LONGER-OVERSIZED |
| MP-N3-C1-T03 | — | — | "n/a (new provider module; DecisionQuery is read only)" | NO-LONGER-OVERSIZED |
| MP-N3-C1-T04 | — | — | "n/a (new provider module)" | NO-LONGER-OVERSIZED |
| MP-N3-C1-T05 | — | — | "n/a (new provider module)" | NO-LONGER-OVERSIZED |
| MP-N3-C2-T01 | — | — | "n/a (new gateway module)" | NO-LONGER-OVERSIZED |
| MP-N3-C2-T02 | — | — | "n/a (new gateway module)" | NO-LONGER-OVERSIZED |
| MP-N4-C3-T07 | — | — | aiur-engine.sh / agent_control_cli.ex owners per U8 ledger | NO-LONGER-OVERSIZED |
| MP-N5-C1-T03 | — | — | router.ex — web-shell owner per U8 ledger | NO-LONGER-OVERSIZED |
| MP-N6-C1-T01 | — | — | router.ex — web-shell owner per U8 ledger | NO-LONGER-OVERSIZED |
| MP-E1-C1-T01 | src/lib/aiur/github/issues.ex | 1207 | "GH_TRUST / GitHub access (github/issues.ex, 1248 lines; provisional, re-check per RC-23)" | MISMATCH (ledger says GH_TRUST) |
| MP-E1-C1-T02 | src/lib/aiur/github/issues.ex | 1207 | "LIFECYCLE_DISPATCH / Ticket lifecycle and dispatch (orchestrator/issue_sync.ex, 2295 lines; provisional, RC-23)" | MISMATCH (ledger says GH_TRUST) |
| MP-E1-C1-T03 | — | — | "GH_TRUST / GitHub access (github/issues.ex, 1248 lines; provisional, RC-23)" | NO-LONGER-OVERSIZED |
| MP-E1-C1-T04 | — | — | "GH_TRUST / GitHub access (github/issue_state.ex; provisional, RC-23)" | NO-LONGER-OVERSIZED |
| MP-E1-C1-T05 | — | — | "LIFECYCLE_DISPATCH / Ticket lifecycle and dispatch (orchestrator/dispatch_policy.ex, 1213 lines; provisional, RC-23)" | NO-LONGER-OVERSIZED |
| MP-E1-C1-T06 | — | — | "LIFECYCLE_DISPATCH / Ticket lifecycle and dispatch (orchestrator.ex, 1003 lines; provisional, RC-23)" | NO-LONGER-OVERSIZED |
| MP-E1-C3-T01 | — | — | "CONFIG / Configuration (config.ex 1462 lines, not edited); config/schema.ex small (provisional, RC-23)" | NO-LONGER-OVERSIZED |
| MP-E1-C3-T03 | — | — | "APP_BOOT / Repository support (src/lib/aiur.ex, 600 lines; provisional, RC-23)" | NO-LONGER-OVERSIZED |
| MP-E1-C3-T04 | — | — | "GH_TRUST (github/tracker.ex, small addition; provisional, RC-23)" | NO-LONGER-OVERSIZED |
| MP-E1-C3-T08 | — | — | "new file; one line in src/config/config.exs (composition root); provisional, RC-23" | NO-LONGER-OVERSIZED |
| MP-E1-C4-T03 | — | — | "GH_TRUST (github/tracker.ex small addition; provisional, RC-23)" | NO-LONGER-OVERSIZED |
| MP-E1-C4-T04 | src/lib/aiur/github/issues.ex | 1207 | "GH_TRUST (github/issues.ex 1248 lines, one-line change; provisional, RC-23)" | MISMATCH (ledger says GH_TRUST) |
| MP-E1-C4-T05 | — | — | "GH_TRUST (github/tracker.ex small addition; provisional, RC-23)" | NO-LONGER-OVERSIZED |
| MP-E1-C6-T01 | — | — | "CLI / npm CLI packaging (aiur-engine.sh 4224 lines) and Agent control CLI (agent_control_cli.ex 3362 lines); provisional, RC-23" | NO-LONGER-OVERSIZED |
| MP-E1-C6-T02 | — | — | "CLI (aiur-engine.sh, agent_control_cli.ex); provisional, RC-23" | NO-LONGER-OVERSIZED |
| MP-E1-C6-T03 | — | — | "CLI (aiur-engine.sh); provisional, RC-23" | NO-LONGER-OVERSIZED |
| MP-E1-C7-T01 | — | — | "APP_BOOT (src/lib/aiur.ex one child line); new file otherwise; provisional, RC-23" | NO-LONGER-OVERSIZED |
| MP-E2-C1-T01 | — | — | "DECISIONS (decision_store.ex 4,826; decision_projection.ex 1,039; decision_event.ex 1,057) — one delegating clause per file only" | NO-LONGER-OVERSIZED |
| MP-E2-C1-T02 | — | — | "DECISIONS (decision_validation.ex 494 — must stay ≤ 500; new logic in commands/request_content.ex)" | NO-LONGER-OVERSIZED |
| MP-E2-C1-T03 | — | — | "DECISIONS (decision_store.ex — two call sites replaced, no growth)" | NO-LONGER-OVERSIZED |
| MP-E2-C1-T04 | — | — | "DECISIONS (decision_api/public_projection.ex 114) + WEB (decision_presenter.ex 168); both stay small" | NO-LONGER-OVERSIZED |
| MP-E2-C2-T01 | — | — | "n/a — new module (≤ 200 lines)" | NO-LONGER-OVERSIZED |
| MP-E2-C2-T02 | — | — | "DECISIONS (decision_store.ex: one public fn + one handle_call; decision_event.ex / decision_projection.ex: list extension only)" | NO-LONGER-OVERSIZED |
| MP-E2-C2-T03 | — | — | "n/a for the new module; DECISIONS for the one-guard edit in decision_store.ex handle_defer" | NO-LONGER-OVERSIZED |
| MP-E2-C2-T04 | — | — | "CLI (aiur-engine.sh; agent_control_cli.ex 3,482 — 4-line delegator only) + DECISIONS (executor_command_cli.ex 387)" | NO-LONGER-OVERSIZED |
| MP-E2-C2-T05 | — | — | "DECISIONS (config/schema/decisions.ex 62; config.ex 1,471 — accessor lines only) + DOCS (configuration.md)" | NO-LONGER-OVERSIZED |
| MP-E2-C3-T01 | — | — | "DECISIONS (decision_store.ex — one guard call in handle_revision/4, actor_source in normalize_actor)" | NO-LONGER-OVERSIZED |
| MP-E2-C3-T02 | — | — | "n/a — new module; WEB untouched here (C3-T03 wires the dashboard)" | NO-LONGER-OVERSIZED |
| MP-E2-C3-T03 | src/test/aiur_web/live/dashboard_live_test.exs | 4982 | "WEB (decision_commands.ex 386; decision_action.ex 198; decision_revision_action.ex) — no file may pass 500" | MISMATCH (ledger says WEB) |
| MP-E2-C3-T04 | — | — | "WEB / DECK_WEB (streamdeck_channel.ex 609 — already over 500: net growth must be ≤ 0, move helpers out) + packages/streamdeck" | NO-LONGER-OVERSIZED |
| MP-E2-C4-T01 | — | — | "n/a — new module (≤ 200 lines)" | NO-LONGER-OVERSIZED |
| MP-E2-C4-T02 | — | — | "CODEX (codex/approvals.ex 356 — one call site); AGENT_CORE (app_server/turn_loop.ex 152); LIFECYCLE (runtime_watchdog.ex 376, token_accounting.ex) — guard lines only" | NO-LONGER-OVERSIZED |
| MP-E2-C4-T03 | — | — | "DECISIONS (decision_dispatch.ex 108); AGENT_CORE (checkpoint_delivery.ex 235, turn_callbacks.ex, app_server/interrupts.ex 76)" | NO-LONGER-OVERSIZED |
| MP-E2-C4-T04 | — | — | "AGENT_CORE (app_server/turn_loop.ex 152; app_server/interrupts.ex 76) — small guards; logic in commands/native_capture/release.ex" | NO-LONGER-OVERSIZED |
| MP-E2-C4-T05 | — | — | "CODEX (codex/config.ex 126; codex/app_server_port.ex 287)" | NO-LONGER-OVERSIZED |
| MP-E2-C5-T01 | — | — | "n/a — external repo its-everdred/claude-app-server (src/server.ts 42 KB; add a new module)" | NO-LONGER-OVERSIZED |
| MP-E2-C5-T02 | — | — | "CLAUDE (claude/coding_agent.ex 534 — already over 500: add one delegating clause, move ≥ equal lines out or coordinate with the U8 CLAUDE owner)" | NO-LONGER-OVERSIZED |
| MP-E2-C5-T03 | — | — | "n/a — logic in commands/native_capture/claude.ex and the sibling module" | NO-LONGER-OVERSIZED |
| MP-E2-C6-T01 | — | — | "CLI (aiur-engine.sh; agent_control_cli.ex 3,482 — delegator only); DECISIONS (one guard in decision_store.ex executor answer policy)" | NO-LONGER-OVERSIZED |
| MP-E2-C6-T02 | — | — | "U3 owner for executor_listener.ex / executor_wake_projection.ex (narrow allowlist only); DECISIONS (one dispatchability guard; decision.ex delivered?/1)" | NO-LONGER-OVERSIZED |
| MP-E2-C6-T03 | — | — | "CLI (asks_cli.ex, aiur-engine.sh run_asks)" | NO-LONGER-OVERSIZED |
| MP-E2-C6-T04 | — | — | "WEB (decision_inbox.ex 154; decision_card.ex 244; units_filters)" | NO-LONGER-OVERSIZED |
| MP-E2-C7-T01 | — | — | "WEB (decision_inbox.ex 154; overview.ex 173; fleet_table.ex 194; decision_card.ex 244)" | NO-LONGER-OVERSIZED |
| MP-E2-C7-T02 | — | — | "WEB (decision_detail.ex 164; decision_action.ex 198; history.ex 300) — new components for the timeline and the multi-question form" | NO-LONGER-OVERSIZED |
| MP-E2-C7-T03 | — | — | "WEB (units_table.ex 412; units_presenter.ex; units_policy.ex); LIFECYCLE (status_report.ex — one field)" | NO-LONGER-OVERSIZED |
| MP-E2-C7-T04 | — | — | "CLI (commands_cli.ex 246)" | NO-LONGER-OVERSIZED |
| MP-E2-C7-T05 | — | — | "WEB / DECK_WEB (streamdeck_commands.ex; streamdeck_channel.ex 609 — no net growth) + packages/streamdeck" | NO-LONGER-OVERSIZED |
| MP-E2-C8-T01 | — | — | "DOCS (concepts/commands.md 68; concepts/executor.md 32 — both small)" | NO-LONGER-OVERSIZED |
| MP-E2-C8-T02 | — | — | "DOCS (.claude/skills/aiur-run/SKILL.md 1,293 — already over 500: put new text in references/executor.md and link; net SKILL.md growth ≤ 5 lines)" | NO-LONGER-OVERSIZED |
| MP-E2-C8-T03 | — | — | "DOCS (.claude/skills/aiur-agent/attention-and-resolve.md, emit-and-subscribe.md); DECISIONS (one default literal)" | NO-LONGER-OVERSIZED |
| MP-E2-C8-T04 | — | — | "DECISIONS (config defaults) + DOCS" | NO-LONGER-OVERSIZED |
| MP-E3-C1-T02 | — | — | "U8 WEB owner (router.ex 361 lines; new controller and plug)" | NO-LONGER-OVERSIZED |
| MP-E3-C1-T03 | — | — | "U8 CLI owner (agent_control_cli.ex and aiur-engine.sh are large; add functions, do not restructure)" | NO-LONGER-OVERSIZED |
| MP-E3-C2-T01 | — | — | "n/a (new module; small option added to claude/transcript_tailer.ex, 260 lines)" | NO-LONGER-OVERSIZED |
| MP-E3-C4-T05 | — | — | "U8 CLI owner (agent_control_cli.ex)" | NO-LONGER-OVERSIZED |
| MP-E3-C6-T01 | — | — | "U8 WEB owner (new LiveView; dashboard_live.ex 2,903 lines must not grow beyond a nav link)" | NO-LONGER-OVERSIZED |
| MP-E3-C6-T02 | — | — | "U8 WEB owner" | NO-LONGER-OVERSIZED |
| MP-E3-C6-T03 | — | — | "U8 WEB owner" | NO-LONGER-OVERSIZED |
| MP-E3-C7-T01 | — | — | "U8 CLI owner" | NO-LONGER-OVERSIZED |
| MP-E4-C1-T03 | — | — | "U8 RUN owner (message_handler.ex 671 lines, session_lifecycle.ex: keep net additions small)" | NO-LONGER-OVERSIZED |
| MP-E4-C2-T02 | — | — | "U8 WEB owner (router.ex 361 lines)" | NO-LONGER-OVERSIZED |
| MP-E4-C4-T02 | — | — | "U8 WEB owner (decision_detail.ex 164 lines; no dashboard_live.ex growth)" | NO-LONGER-OVERSIZED |
| MP-E4-C5-T01 | — | — | "U8 WEB owner (new LiveView; dashboard_live.ex 2,903 lines must not grow)" | NO-LONGER-OVERSIZED |
| MP-E4-C5-T02 | — | — | "U8 WEB owner (new component module)" | NO-LONGER-OVERSIZED |
| MP-E4-C5-T03 | — | — | "U8 WEB owner" | NO-LONGER-OVERSIZED |
| MP-E4-C5-T04 | — | — | "U8 WEB owner (conversation_drawer.ex 276 lines; dashboard_live.ex must not grow beyond the link assign)" | NO-LONGER-OVERSIZED |
| MP-E4-C6-T01 | — | — | "U8 WEB owner (new component; no dashboard_live.ex growth)" | NO-LONGER-OVERSIZED |
| MP-E4-C6-T02 | — | — | "U8 WEB owner" | NO-LONGER-OVERSIZED |
| MP-E4-C7-T01 | — | — | "U8 SD owner (streamdeck_logs.ex 637 lines; this ticket reduces or keeps it)" | NO-LONGER-OVERSIZED |
| MP-E5-C1-T01 | — | — | WEB (conversation_drawer.ex is 276 lines; no split needed) | NO-LONGER-OVERSIZED |
| MP-E5-C1-T02 | — | — | BROWSER (conversation-voice-controller.js, 539 lines, over the 500-line U8 ceiling) | NO-LONGER-OVERSIZED |
| MP-E5-C1-T03 | — | — | BROWSER (layouts.ex is 336 lines; new hook file is small) | NO-LONGER-OVERSIZED |
| MP-E5-C2-T01 | — | — | WEB (voice_channel.ex is 331 lines; target validation goes to a new module) | NO-LONGER-OVERSIZED |
| MP-E5-C2-T02 | — | — | WEB (voice_channel.ex) | NO-LONGER-OVERSIZED |
| MP-E5-C2-T03 | — | — | WEB (dashboard_live.ex 2,903 lines — the change is net-neutral: one assign line; logic lives in a new module) | NO-LONGER-OVERSIZED |
| MP-E5-C3-T01 | — | — | BROWSER (controller), WEB (component) | NO-LONGER-OVERSIZED |
| MP-E5-C3-T02 | — | — | WEB | NO-LONGER-OVERSIZED |
| MP-E5-C3-T03 | — | — | BROWSER (controller), WEB (voice_channel.ex) | NO-LONGER-OVERSIZED |
| MP-E5-C4-T01 | — | — | WEB (decision_action.ex is 198 lines) | NO-LONGER-OVERSIZED |
| MP-E5-C4-T02 | — | — | WEB (decision_revision_action.ex) | NO-LONGER-OVERSIZED |
| MP-E5-C5-T01 | — | — | WEB (agent_log_modal.ex is 181 lines) | NO-LONGER-OVERSIZED |
| MP-E5-C6-T01 | — | — | BROWSER (conversation-voice-controller.js after the C1-T02 split) | NO-LONGER-OVERSIZED |
