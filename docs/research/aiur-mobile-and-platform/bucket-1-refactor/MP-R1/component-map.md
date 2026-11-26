# MP-R1 component map

Part of the [MP-R1 plan](https://github.com/aiur-team/aiur/blob/de341053cc16d2e6096a3a0d0fbacb43ef9f6eb0/docs/research/aiur-mobile-and-platform/bucket-1-refactor/MP-R1/plan.md). This file names every component, maps it to the
prior boundary survey, and gives its public interface, its required and optional
dependencies, and the configuration and state it owns. The
[capability matrix](https://github.com/aiur-team/aiur/blob/de341053cc16d2e6096a3a0d0fbacb43ef9f6eb0/docs/research/aiur-mobile-and-platform/bucket-1-refactor/MP-R1/capability-matrix.md) says what works when a component is absent.
The [migration plan](migration-plan.md) says in which order the components get their
boundaries.

Base: `origin/main` at `45a290e3` (2026-10-06). Prior research:
`docs/research/refactor-2026-09-26/codebase/feature-boundaries.md` (40 proposed
boundaries, 36 measured, at `0972f0297`), corrected by
`synthesis/architecture-verification.md`. Codes in the `Prior` column are that
survey's boundary codes (`K`, `CFG`, `BUS` ...) and entry numbers (#1–#40).

## 1. What a "component" means here

This map does **not** propose 30 Mix applications. KTD3 and KTD11 of the September
plan stand: ownership and typed contracts come first, and a physical package moves
only when its startup, state, recovery and test contracts move intact. "A count of
packages is not a success measure."

A component (decision MP-R1-KD1, [plan.md §4](https://github.com/aiur-team/aiur/blob/de341053cc16d2e6096a3a0d0fbacb43ef9f6eb0/docs/research/aiur-mobile-and-platform/bucket-1-refactor/MP-R1/plan.md)) is:

1. one entry in the machine-readable component manifest (`components.json`, MP-R1-C1);
2. a declared set of source paths (today's paths, updated at each move);
3. one or more **facade modules** that other components may call; everything else in
   the component is private;
4. declared **required** and **optional** dependencies on other components;
5. the config sections, environment variables, state paths and capabilities it owns.

A dependency checker (MP-R1-C1) fails CI when code in component A references a
private module of component B, or references B at all when B is not declared. A
component becomes a physical package (Mix app, npm workspace package or repository)
only when the promotion test in [migration-plan.md §5](migration-plan.md) passes.

Levels, as in the prior survey: **core** (named boundary in the main app),
**package** (own Mix app or npm package in this repo), **repo** (own repository).
The "Target" column is the end state; "Now" is the first step.

## 2. Layers and the dependency rule

```text
L5 clients      mobile app, watch apps, Stream Deck sidecar, browser dashboard JS
                  (talk to L4 over versioned wire contracts only)
L4 surfaces     web-shell/API, dashboard UI, TUI, CLI verbs, launcher, init
L3 features     orchestration, build-queue, build-orders, commands, conversations,
                  executor-attention, voice-stt, voice-conversation, listener-modes,
                  pairing-discovery, push-relay, streamdeck-server, projections,
                  machine-gateway (planned), notification-policy (planned)
L2 domain       harness adapters, agent runner, workspace, agent sandbox,
                  github family, github-listeners, linear, tracker contract,
                  accounting, telemetry
L1 spine        event bus, signal port, identity-and-capabilities, web-kit
L0 foundation   kernel, config
```

Rules (checked by MP-R1-C1):

- **R-down.** A component may depend only on components in its own layer or lower.
  An upward need is met by a behaviour/callback registered at boot, or by an event.
  The prior survey's six upward-edge classes (`Alerts`, `RunTelemetry`, calls back
  into `Aiur.Orchestrator`, `Config` validating through feature modules, registries
  naming adapters, generic primitives inside features) are the known violations.
- **R-optional.** A required component never depends on an optional one. Optional
  components attach through registration (config section, CLI verbs, child specs,
  capabilities, routes) at the composition root.
- **R-client.** An L5 client depends only on published wire contracts
  (`packages/aiur-contracts`, MP-R1-C3). It never imports from `src/`, and never
  infers capability from a missing field.
- **R-cycle.** The 35-boundary strongly connected component is the baseline. The
  checker records today's violations as a ratcheting allowlist: the count may only
  go down. This avoids a big-bang gate.

## 3. Component table

The Paths today column is measured at `4fbe109541ba1e279d3eb315d8455c4d139c92ba`. Other columns retain the research design; the [complete current manifest inventory](../../refresh/MP-R1-C11-T03/component-paths.md) includes components introduced since that design. Physical packages are not inferred from logical ownership.

"Req" = required dependencies. "Opt" = optional dependencies, used only when present.
Facades are today's modules where they exist; `(new)` marks a facade to be created.
Line counts are from the prior survey at `0972f0297` unless re-measured at `45a290e3`
(marked †).

### L0 — Foundation

| ID | Component | Prior | Paths today | Facade / public interface | Req | Opt | Owns config / state | Kind | Target |
|---|---|---|---|---|---|---|---|---|---|
| `kernel` | Kernel primitives | `K` #1 | `src/lib/aiur/boot.ex`, `src/lib/aiur/bounded.ex`, `src/lib/aiur/build_stamp.ex`, `src/lib/aiur/coordination_tasks.ex`, `src/lib/aiur/display_sanitizer.ex`, `src/lib/aiur/fs.ex`, `src/lib/aiur/git.ex`, `src/lib/aiur/handoff/protection.ex`, `src/lib/aiur/journal.ex`, `src/lib/aiur/json_safe.ex`, `src/lib/aiur/json_store.ex`, `src/lib/aiur/jsonl.ex`, `src/lib/aiur/local_test_evidence.ex`, `src/lib/aiur/opaque_identifier.ex`, `src/lib/aiur/os.ex`, `src/lib/aiur/path_safety.ex`, `src/lib/aiur/periodic_worker.ex`, `src/lib/aiur/pr_body_lint.ex`, `src/lib/aiur/process_exhaustion.ex`, `src/lib/aiur/process_identity.ex`, `src/lib/aiur/process_tree.ex`, `src/lib/aiur/protocol/**`, `src/lib/aiur/secret_redactor.ex`, `src/lib/aiur/shell.ex`, `src/lib/aiur/ssh.ex`, `src/lib/aiur/start_trigger.ex`, `src/lib/aiur/start_trigger/**`, `src/lib/aiur/system_cgroup.ex`, `src/lib/aiur/system_pressure.ex`, `src/lib/aiur/test_run_state.ex`, `src/lib/aiur/tracker_identity.ex`, `src/lib/aiur/yaml.ex`, `src/priv/pidfd_reap.py` | `Aiur.Fs`, `JsonStore`, `Jsonl`, `PathSafety`, `SecretRedactor`, `PeriodicWorker`, crash-safe journal (moved out of `DecisionLog`) | — | — | none | required | package `aiur_kernel` |
| `config` | Config and workflow | `CFG` #2 | `src/lib/aiur/agent_config.ex`, `src/lib/aiur/config.ex`, `src/lib/aiur/config/**`, `src/lib/aiur/env.ex`, `src/lib/aiur/env/**`, `src/lib/aiur/handoff/record.ex`, `src/lib/aiur/instance.ex`, `src/lib/aiur/instance/**`, `src/lib/aiur/merge_policy.ex`, `src/lib/aiur/workflow.ex`, `src/lib/aiur/workflow_store.ex`, `src/lib/aiur/workflow_store/**` | `Aiur.Config` (accessors), `Config.Paths`, schema **registration** (new) | kernel | — | `.aiur/config` load, `~/.aiur/config` fallback, `.env` precedence, path registry | required | package `aiur_config` |

### L1 — Spine

| ID | Component | Prior | Paths today | Facade / public interface | Req | Opt | Owns config / state | Kind | Target |
|---|---|---|---|---|---|---|---|---|---|
| `event-bus` | Event exchange and subscriptions (MP-R2) | `BUS` #10 | `src/lib/aiur/agent_events.ex`, `src/lib/aiur/agent_pubsub.ex`, `src/lib/aiur/agent_pubsub/**`, `src/lib/aiur/events.ex`, `src/lib/aiur/events/agent_subscription_policy.ex`, `src/lib/aiur/events/delivery.ex`, `src/lib/aiur/events/durable_consumer.ex`, `src/lib/aiur/events/durable_consumer/handler.ex`, `src/lib/aiur/events/durable_consumer/journal_source.ex`, `src/lib/aiur/events/durable_consumer/source.ex`, `src/lib/aiur/events/exchange.ex`, `src/lib/aiur/events/history_store.ex`, `src/lib/aiur/events/id_generator.ex`, `src/lib/aiur/events/journal.ex`, `src/lib/aiur/events/journaled_publish.ex`, `src/lib/aiur/events/publisher.ex`, `src/lib/aiur/events/source_policy.ex`, `src/lib/aiur/events/source_policy/null.ex`, `src/lib/aiur/events/subscription_store.ex`, `src/lib/aiur/events/subscription_store/persistence.ex`, `src/lib/aiur/events/subscription_store/processing.ex`, `src/lib/aiur/events/subscription_store_supervisor.ex`, `src/lib/aiur/events/topic.ex`, `src/lib/aiur/events/trace.ex`, `src/lib/aiur/events/trust_classifier.ex`, `src/lib/aiur/events/universal_subscriptions.ex`, `src/lib/aiur/ticket_observation.ex` | `Events.Publisher.publish/3`, `Exchange.subscribe/2`, `Topic`, `TicketObservation`; external subscriber API (MP-R2) | kernel, config | — | `events.*`; `event-id.json`, `subscriptions/*.json` | required | package `aiur_events` (MP-R2 owns) |
| `signal` | Signal and telemetry port | #11 (new) | `src/lib/aiur/log_file.ex`, `src/lib/aiur/perf.ex`, `src/lib/aiur/signal.ex` | `Signal.alert/2` (new), `:telemetry` events | kernel, event-bus | — | none (consumers own sinks) | required | package (kernel layer) |
| `identity` | Identity and capabilities (MP-R1) | none (new) | `src/lib/aiur/capabilities.ex`, `src/lib/aiur/capabilities/**`, `src/lib/aiur/identity.ex`, `src/lib/aiur/identity/**`, `src/lib/aiur_web/controllers/capabilities_controller.ex`, `src/lib/aiur_web/routes/capabilities.ex` | `Aiur.Identity` (new), `Aiur.Capabilities` (new); **registers** `AiurWeb.Routes.Capabilities` (`GET /api/v1/capabilities`), which web-shell composes (RC-39) | kernel, config, web-kit | — | `~/.config/aiur/machine/identity.json` (shared with MP-N2's machine store), capability registry | required | core; wire contract in `packages/aiur-contracts` |
| `web-kit` | Phoenix helper library for component route, socket and controller modules (RC-39) | part of `WEB` #34 | `src/lib/aiur_web/capability_error.ex`, `src/lib/aiur_web/kit.ex`, `src/lib/aiur_web/provider_meter_windows.ex`, `src/lib/aiur_web/refresh_relay.ex`, `src/lib/aiur_web/remaining_meter.ex` | `use AiurWeb.Kit, :controller \| :channel \| :live_view`, `AiurWeb.CapabilityError.render/2`; no endpoint, no routes, no pipelines | kernel, config | — | none | required | core; `added_by: MP-R1` |

### L2 — Domain

| ID | Component | Prior | Paths today | Facade / public interface | Req | Opt | Owns config / state | Kind | Target |
|---|---|---|---|---|---|---|---|---|---|
| `tracker` | Tracker contract | `TRK` #3 | `src/lib/aiur/code_host.ex`, `src/lib/aiur/code_host/**`, `src/lib/aiur/issue.ex`, `src/lib/aiur/memory/**`, `src/lib/aiur/optimistic_start.ex`, `src/lib/aiur/ticket_branch.ex`, `src/lib/aiur/tracker.ex`, `src/lib/aiur/tracker/**`, `src/lib/aiur/tracker_config.ex` | `Aiur.Tracker` split into IssueTracker and CodeHost ports; adapter registration replaces the `case` in `Tracker.adapter/0` | kernel, config | — | `tracker.kind` | required | package `aiur_tracker` |
| `github-access` | GitHub access layer: transport, read cache and policy, budget broker and ledger, credential pool, request ledger and cost, agent `gh` wrapper (split from `github`, 2026-10-09; [design](https://github.com/aiur-team/aiur/blob/de341053cc16d2e6096a3a0d0fbacb43ef9f6eb0/docs/research/aiur-mobile-and-platform/bucket-1-refactor/MP-R1/github-access/brainstorm.md)) | `GHC` `GHB` `GHR` #5–#7 | `src/lib/aiur/github/access.ex`, `src/lib/aiur/github/access/**`, `src/lib/aiur/github/agent_cache**`, `src/lib/aiur/github/agent_cache_bridge**`, `src/lib/aiur/github/app_credentials**`, `src/lib/aiur/github/app_token**`, `src/lib/aiur/github/app_token_refresher**`, `src/lib/aiur/github/auth_preflight**`, `src/lib/aiur/github/broker_timeout**`, `src/lib/aiur/github/budget**`, `src/lib/aiur/github/budget_broker**`, `src/lib/aiur/github/budget_ledger**`, `src/lib/aiur/github/connectivity**`, `src/lib/aiur/github/credential**`, `src/lib/aiur/github/credential_headroom**`, `src/lib/aiur/github/credential_registry**`, `src/lib/aiur/github/credential_selector**`, `src/lib/aiur/github/credential_usage**`, `src/lib/aiur/github/cycle_fetch_cache**`, `src/lib/aiur/github/endpoint_policy**`, `src/lib/aiur/github/errors**`, `src/lib/aiur/github/graphql_cost**`, `src/lib/aiur/github/graphql_errors**`, `src/lib/aiur/github/hold_sweep**`, `src/lib/aiur/github/host_command**`, `src/lib/aiur/github/local_hold**`, `src/lib/aiur/github/membership_access**`, `src/lib/aiur/github/quota**`, `src/lib/aiur/github/read_cache**`, `src/lib/aiur/github/request_log**`, `src/lib/aiur/github/request_origin**`, `src/lib/aiur/github/resource_events**`, `src/lib/aiur/github/resource_fetch**`, `src/lib/aiur/github/resource_store**`, `src/lib/aiur/github/transport**`, `src/priv/github_budget*.py`, `src/priv/github_guard/gh/**` | `Aiur.GitHub.Access` (new, MP-R1-GHA-4); settings provider `Aiur.GitHub.Access.SettingsProvider` (MP-R1-GHA-2); freshness port (MP-R1-GHA-3); standalone `gh-access` wrapper (MP-R1-GHA-5) | kernel, signal | — | `GITHUB_TOKEN`, `GH_TOKEN`, `GITHUB_APP_*`, `AIUR_GITHUB_BUDGET_*`, `AIUR_GITHUB_STATE_CACHE_*`; `~/.aiur/github-budget/`, `<repo-state>/github-quota/`, `github_resources.json` (root injectable) | optional | in-repo Mix project `packages/elixir/aiur_github_access` only when the §5 promotion test passes (MP-R1-GHA-6); wrapper in `packages/gh-access/` |
| `github` | GitHub tracker and code-host domain (client, issues, labels, PRs, review threads, CI readiness, trust, poll batches); access layer split out to `github-access` (MP-R1-GHA-1) | `GHD` #8 | `src/lib/aiur/allowed_contributors.ex`, `src/lib/aiur/allowed_contributors/**`, `src/lib/aiur/ci/failure_digest.ex`, `src/lib/aiur/ci/transient_network_failure.ex`, `src/lib/aiur/ci_approval_store.ex`, `src/lib/aiur/codeowners.ex`, `src/lib/aiur/codeowners/**`, `src/lib/aiur/github/**`, `src/lib/aiur/github_cost_cli.ex`, `src/lib/aiur/github_cost_cli/**`, `src/lib/aiur/github_usage_cli.ex`, `src/lib/aiur/global_config_startup.ex`, `src/lib/aiur/open_ticket_source.ex`, `src/lib/aiur/open_ticket_source/**`, `src/lib/aiur/pr_merge/queue.ex`, `src/lib/aiur/webhooks/delivery_mode.ex` | `GitHub.Tracker` (IssueTracker+CodeHost impl), `GitHub.Labels` | kernel, config, tracker, signal, github-access | event-bus | `tracker.github.*`, `polling.*` (GitHub cadence), `GITHUB_TOKEN`, `GITHUB_APP_*`; budget ledger, resource store | optional (one tracker is required; config enforces it) | package after github-access is promoted; repo candidate |
| `github-listeners` | GitHub event ingestion (webhook + pollers) | `ING` #9 | `src/lib/aiur/events/branch_ref_store.ex`, `src/lib/aiur/events/branch_rewrite_classifier.ex`, `src/lib/aiur/events/comment_filter.ex`, `src/lib/aiur/events/github*.ex`, `src/lib/aiur/events/github_ci_poller/**`, `src/lib/aiur/events/github_comments_poller/**`, `src/lib/aiur/events/github_firehose/**`, `src/lib/aiur/events/github_webhook/**`, `src/lib/aiur/events/ls_remote_ticker.ex`, `src/lib/aiur/events/post_deploy_checks.ex`, `src/lib/aiur/events/pr_command_scanner.ex`, `src/lib/aiur/events/sanitizer.ex`, `src/lib/aiur/github/listeners.ex`, `src/lib/aiur/github/listeners/**`, `src/lib/aiur/main_watch.ex`, `src/lib/aiur/main_watch/**`, `src/lib/aiur/poll_cadence.ex`, `src/lib/aiur/poll_cadence/**`, `src/lib/aiur/stacking/**`, `src/lib/aiur/webhooks.ex`, `src/lib/aiur/webhooks/**`, `src/lib/aiur_web/controllers/github_webhook_controller.ex`, `src/lib/aiur_web/github_webhook*`, `src/lib/aiur_web/routes/github_webhook.ex` | normalized events on `event-bus`; deposits into `github` resource store; `Webhooks.EventSource` behaviour (already clean); **registers** `AiurWeb.Routes.GithubWebhook` (RC-39) | github, event-bus, config, web-kit | — | `webhooks.*`, `AIUR_GITHUB_WEBHOOK_SECRET`; delivery log; **cursor fields move out of `Orchestrator.State`** | optional | package after the `GitHub.Listeners` process split |
| `linear` | Linear adapter | `LIN` #4 | `src/lib/aiur/linear/**` | IssueTracker impl | tracker, config | — | `tracker.linear.*` | optional | repo candidate |
| `agent-sandbox` | Agent OS-process safety | #17 (split from `RUN`) | `src/lib/aiur/agent_build_guard.ex`, `src/lib/aiur/agent_command_installer.ex`, `src/lib/aiur/agent_environment.ex`, `src/lib/aiur/agent_environment/**`, `src/lib/aiur/agent_github_guard.ex`, `src/lib/aiur/agent_github_guard/**`, `src/lib/aiur/agent_process_log.ex`, `src/lib/aiur/agent_process_log/**`, `src/lib/aiur/agent_resource_guard.ex`, `src/lib/aiur/agent_resource_guard/**`, `src/lib/aiur/agent_scratch.ex`, `src/lib/aiur/agent_shell_hook.ex`, `src/lib/aiur/build_gate.ex`, `src/lib/aiur/build_gate/**`, `src/lib/aiur/build_gate_hold_monitor.ex`, `src/lib/aiur/pause_containment.ex`, `src/lib/aiur/process_reaper.ex`, `src/lib/aiur/sandbox/**` | `AgentEnvironment.build/…`, `ProcessReaper`, `BuildGate` | kernel, config | — | `agent.max_concurrent_builds`, env scrubbing rules | required | package `aiur_agent_sandbox` |
| `workspace` | Workspace and repo base | `WS` #19 | `src/lib/aiur/prewarm/**`, `src/lib/aiur/repo_base.ex`, `src/lib/aiur/repo_base/**`, `src/lib/aiur/workspace.ex`, `src/lib/aiur/workspace/**` | `Workspace`, `Workspace.Ownership`, `RepoBase` | kernel, config, agent-sandbox, tracker | — | `workspace.*`, `hooks.*`, `prewarm.*` | required | package `aiur_workspace` |
| `harness-adapters` | Harness adapter package (MP-R7) | `CA` `CDX` `CLD` `OAI` #20–#23, plus Muse (not in the prior survey) | `src/lib/aiur/agent_tools/**`, `src/lib/aiur/app_server/**`, `src/lib/aiur/claude/**`, `src/lib/aiur/codex/**`, `src/lib/aiur/codex_prober.ex`, `src/lib/aiur/coding_agent.ex`, `src/lib/aiur/coding_agent/**`, `src/lib/aiur/harness/**`, `src/lib/aiur/model_availability.ex`, `src/lib/aiur/model_availability/**`, `src/lib/aiur/model_catalog.ex`, `src/lib/aiur/model_discovery.ex`, `src/lib/aiur/model_discovery/**`, `src/lib/aiur/muse/**`, `src/lib/aiur/open_ai_compat/**`, `src/lib/aiur/rtk.ex`, `src/lib/aiur/rtk_startup_check.ex`, `src/priv/agent_relay.py`, `src/priv/claude_hook_spool.py` | `CodingAgent.Backend` behaviour plus capability callbacks (remote session, resume, interrupt, native-question capture); backends self-register | agent-sandbox, config, kernel | accounting | `agent.*` routing, backend sections (`muse_backend`, `opencode`), provider keys | required | package `aiur_harness`; per-harness repo candidates (MP-R7 owns) |
| `agent-runner` | Turn engine for one ticket | `RUN` #18 | `src/lib/aiur/agent_compaction/**`, `src/lib/aiur/agent_context_presentation.ex`, `src/lib/aiur/agent_directory.ex`, `src/lib/aiur/agent_event_log.ex`, `src/lib/aiur/agent_runner.ex`, `src/lib/aiur/agent_runner/**`, `src/lib/aiur/agent_skills.ex`, `src/lib/aiur/agent_status_note.ex`, `src/lib/aiur/event_publication_log.ex`, `src/lib/aiur/issue_context.ex`, `src/lib/aiur/issue_log.ex`, `src/lib/aiur/issue_log/**`, `src/lib/aiur/live_conversation.ex`, `src/lib/aiur/live_conversation/**`, `src/lib/aiur/logs/**`, `src/lib/aiur/prompt_builder.ex`, `src/lib/aiur/session_handle.ex` | spawn API given an owner pid (replaces 8 calls back into `Aiur.Orchestrator`) | harness-adapters, workspace, agent-sandbox, event-bus, tracker | — (the old upward Opt edge to `listener-modes` is removed: the listener reaches a running turn through harness-adapter steer callbacks and the `Aiur.Listener.DeliveryTarget` port, RC-36) | per-issue logs, session handles | required | core |
| `accounting` | Provider meters and usage ledger | `PM`+`USG` #25 | `src/lib/aiur/accounting/**`, `src/lib/aiur/accounts.ex`, `src/lib/aiur/accounts/**`, `src/lib/aiur/agent/**`, `src/lib/aiur/provider_account_generation.ex`, `src/lib/aiur/provider_account_generation/**`, `src/lib/aiur/provider_meter_probe.ex`, `src/lib/aiur/provider_meter_projection.ex`, `src/lib/aiur/provider_meter_projection/**`, `src/lib/aiur/provider_meter_refresh.ex`, `src/lib/aiur/provider_meter_snapshot.ex`, `src/lib/aiur/provider_meters.ex`, `src/lib/aiur/provider_meters/**`, `src/lib/aiur/token_usage.ex`, `src/lib/aiur/usage.ex`, `src/lib/aiur/usage/**`, `src/lib/aiur/usage_aggregate.ex`, `src/lib/aiur/usage_aggregate/**`, `src/lib/aiur/usage_compaction/**`, `src/lib/aiur/usage_envelope.ex`, `src/lib/aiur/usage_envelope/**`, `src/lib/aiur/usage_ledger.ex`, `src/lib/aiur/usage_ledger/**` | `ProviderMeterProjection`, `UsageAggregate` | kernel, config | — | `pricing_policy`, usage ledger dirs | optional | package `aiur_accounting` |
| `telemetry` | Run telemetry and host health | `TEL` #29 | `src/lib/aiur/background_cpu.ex`, `src/lib/aiur/daemon_heartbeat.ex`, `src/lib/aiur/daemon_heartbeat_checker.ex`, `src/lib/aiur/daemon_heartbeat_writer.ex`, `src/lib/aiur/metrics.ex`, `src/lib/aiur/run_telemetry.ex`, `src/lib/aiur/run_telemetry/**`, `src/lib/aiur/saturation_sentinel.ex`, `src/lib/aiur/supervision_health.ex`, `src/lib/aiur/supervision_health/**`, `src/lib/aiur/system_cpu.ex`, `src/lib/aiur/system_file_descriptors.ex`, `src/lib/aiur/system_load.ex`, `src/lib/aiur/system_memory.ex`, `src/lib/aiur/system_priority.ex` | `:telemetry` consumer | kernel, config, signal | — | `monitoring.*` | optional | package `aiur_telemetry` |

### L3 — Features

| ID | Component | Prior | Paths today | Facade / public interface | Req | Opt | Owns config / state | Kind | Target |
|---|---|---|---|---|---|---|---|---|---|
| `orchestration` | Poll cycle, dispatch, control lifecycle, PR/CI lifecycle, operator messaging | `ORC` `DSP` `CTL` `PRL` `MSG` #12–#16 | `src/lib/aiur/agent_chat.ex`, `src/lib/aiur/agent_queue.ex`, `src/lib/aiur/agent_queue_item.ex`, `src/lib/aiur/agent_queue_store.ex`, `src/lib/aiur/agent_queue_store/**`, `src/lib/aiur/current_run_membership.ex`, `src/lib/aiur/current_run_membership/**`, `src/lib/aiur/dispatch_budget_store.ex`, `src/lib/aiur/handoff.ex`, `src/lib/aiur/handoff/adopter.ex`, `src/lib/aiur/handoff/compatibility.ex`, `src/lib/aiur/handoff/fallback.ex`, `src/lib/aiur/handoff/report.ex`, `src/lib/aiur/landing_watch.ex`, `src/lib/aiur/landing_watch/**`, `src/lib/aiur/orchestrator.ex`, `src/lib/aiur/orchestrator/**`, `src/lib/aiur/orchestrator/comment_polling_state.ex`, `src/lib/aiur/pr_ready_ledger_store.ex`, `src/lib/aiur/recent_merge.ex`, `src/lib/aiur/recent_merge/**`, `src/lib/aiur/recent_merge_store.ex`, `src/lib/aiur/test_quarantine.ex`, `src/lib/aiur/test_quarantine/**`, `src/lib/aiur/ticket_markers.ex` | `Aiur.Orchestrator` control API (status, pause, resume, `send_operator_message/2`), `AgentChat.send/3` (delegates to `Aiur.Listener.send/3`), `DispatchPolicy` (pure); **implements** `Aiur.Listener.DeliveryTarget` (RC-36), the commands delivery-target port (MP-R1-C8-T02, CR-C8-3) and `Aiur.BuildQueue.ClaimProbe` (RC-11) | tracker, agent-runner, event-bus, signal, config, identity, listener-modes, commands | github-listeners; build-queue **only through two seams** (MP-R1-C1-T06): `Aiur.BuildQueue.Hints` read by `DispatchPolicy`, and `ClaimProbe` implemented here (RC-11) | `agent.max_concurrent_*`, load governor keys, `pr_health`, `pr_watch`, `worker`; `Orchestrator.State` | required | core; `DispatchPolicy` as package `aiur_dispatch_policy` |
| `build-queue` | Build queue (MP-E1, new; ships before the refactor on a seam) | none | `src/lib/aiur/build_queue.ex`, `src/lib/aiur/build_queue/**`, `src/lib/aiur/build_queue_cli.ex` | `Aiur.BuildQueue` (CLI verbs `queue add/remove/reorder/hold/release/show`, read model), `Aiur.BuildQueue.Hints` (ETS rank/hold read by `DispatchPolicy`), behaviour `Aiur.BuildQueue.ClaimProbe` (implemented by orchestration) — RC-11/X-1, manifest `seams` in MP-R1-C1-T06; capability provider for `build_queue` and `build_queue.build_order_source` (MP-E1-C3-T08) | tracker, event-bus, config, identity | build-orders (dependency source; the queue is one producer of `Aiur.BuildProgress`, RC-40) | `build_queue.*` (proposed), queue journal under a new `Config.Paths` key | optional | core now; package after R1 |
| `build-orders` | Build Order graph, catalog, progress, pages | `BO` #30 | `src/lib/aiur/build_order/**`, `src/lib/aiur/build_order_funnel_health.ex`, `src/lib/aiur/build_orders_cli.ex`, `src/lib/aiur/build_progress.ex`, `src/lib/aiur/epic_cli.ex`, `src/lib/aiur/feature_cli.ex`, `src/lib/aiur/feature_cli/**`, `src/lib/aiur_web/build_order*.ex`, `src/lib/aiur_web/build_order/**`, `src/lib/aiur_web/build_order_presenter/**` | `BuildOrder.GitHubGraph`, `RootSummary.progress`, `Readiness.from_edges/1`, `AiurWeb.BuildOrder.DataSource` behaviour (16 callbacks, already clean), **`Aiur.BuildProgress`** (`facts/1`, `subscribe/0`, PubSub `"build_progress"`; RC-40); **registers** `AiurWeb.Routes.BuildOrders` (pages) | tracker, github, config, web-kit | — | `build_order.*`; catalog store; progress facts | optional | package now; repo candidate |
| `commands` | Commands (code: Decisions) and Asks | `DEC` #27, `Asks` from `EXE` | `src/lib/aiur/asks.ex`, `src/lib/aiur/asks_store.ex`, `src/lib/aiur/commands.ex`, `src/lib/aiur/commands/**`, `src/lib/aiur/decision*.ex`, `src/lib/aiur/decision_api/**`, `src/lib/aiur/decision_attention/**`, `src/lib/aiur/decision_dispatch_tasks/**`, `src/lib/aiur/decision_event/**`, `src/lib/aiur/decision_history/**`, `src/lib/aiur/decision_metrics/**`, `src/lib/aiur/decision_projection/**`, `src/lib/aiur/decision_query/**`, `src/lib/aiur/decision_store/**`, `src/lib/aiur/decision_validation/**`, `src/lib/aiur/operator_relay.ex`, `src/lib/aiur/supervisor_token.ex`, `src/lib/aiur/supervisor_token/**`, `src/lib/aiur_web/controllers/decision*.ex`, `src/lib/aiur_web/routes/decisions.ex` | `DecisionStore.request/answer/...`, `Aiur.Commands.Answering`; answer delivery is a **synchronous call through a delivery-target port** that orchestration implements (MP-R1-C8-T02); the `decision.answered` event only wakes the orchestrator (CR-C8-3); **registers** `AiurWeb.Routes.Decisions` (Supervisor Decision API `/api/v1/decisions*`) | event-bus, kernel, config, identity, signal, web-kit | — | `decisions.*`, `AIUR_SUPERVISOR_TOKEN`; `decisions.ndjson` | required (the dispatch gate fails closed when the store is unreadable, CR-C8-3) | package `aiur_decisions`; repo candidate |
| `executor-attention` | Wake inbox, claims, roster, principal, alerts ledger, progress check-in | `EXE` #26 | `src/lib/aiur/alert_*.ex`, `src/lib/aiur/alert_feed/**`, `src/lib/aiur/alert_ledger/**`, `src/lib/aiur/alerts.ex`, `src/lib/aiur/alerts/**`, `src/lib/aiur/executor/**`, `src/lib/aiur/executor_*.ex`, `src/lib/aiur/executor_attention/**`, `src/lib/aiur/executor_events/**`, `src/lib/aiur/executor_sweep/**`, `src/lib/aiur/executor_wake_inbox/**`, `src/lib/aiur/operator_wait_log.ex`, `src/lib/aiur/progress_checkin/**`, `src/lib/aiur/usage/alerts.ex` | `executor-wait/-listen/-claim` verbs, `ExecutorEvents`, `AlertFeed`; capability provider for `executor.*` (incl. `executor.conversation`, MP-R1-C3-T02) | event-bus, signal, kernel, config, identity, commands | conversations | `alerts.*`; `~/.aiur/repo/<owner>/<repo>/executor/*` | optional (default on with recording) | package `aiur_executor` |
| `projections` | Current-run read models | `PRJ` #28 | `src/lib/aiur/current_run_outcome_snapshot.ex`, `src/lib/aiur/current_run_outcome_snapshot/**`, `src/lib/aiur/current_run_projection/**`, `src/lib/aiur/current_run_projections.ex`, `src/lib/aiur/current_run_projections/**`, `src/lib/aiur/current_run_summary.ex`, `src/lib/aiur/current_run_summary/**`, `src/lib/aiur/progress_retention.ex`, `src/lib/aiur/progress_retention/**`, `src/lib/aiur/progress_tracker.ex`, `src/lib/aiur/projections/**`, `src/lib/aiur/ticket_activity.ex`, `src/lib/aiur/ticket_activity/**` | read-only snapshot APIs; fed from events | event-bus, tracker, kernel | — | membership store | required | package `aiur_projections` |
| `conversations` | Transcript access and event-to-conversation anchors (MP-E4 owns the contract) | part of `PRJ` and `RUN`; anchor logic in `SD` #35 | `src/lib/aiur/agent_event_feed.ex`, `src/lib/aiur/agent_log.ex`, `src/lib/aiur/agent_log/**`, `src/lib/aiur/conversation/anchors.ex`, `src/lib/aiur/conversation/history.ex` | `Aiur.Conversation.History` read facade, replacing device-named `AiurWeb.StreamdeckLogs` (MP-R6 moves it) | event-bus, agent-runner (logs), identity | executor-attention (Executor stream, MP-E3) | none beyond log paths | optional (every surface that needs it is optional) | core then package |
| `listener-modes` | Listener send router, mode store and scheduler (MP-E7; RC-36) | none | — (no current source paths) | `Aiur.Listener.send/3` (the only send API for E3, E4, E5, E6, N6), mode store, scheduler; behaviour `Aiur.Listener.DeliveryTarget` (implemented by orchestration, registered at the composition root); capability provider for `listener_modes` (MP-E7-C3-T06). Reads the vendored `listener-spec` at build time; spec absent → `:legacy` routing and `listener_modes: unavailable/not_installed`; checksum or schema failure → `:legacy` and `unavailable/spec_invalid` | harness-adapters, event-bus, config, identity | — | per-agent mode; `:listener_send_routing` flag (RC-05) | required (it is the send router) | core (MP-E7 owns) |
| `voice-stt` | Speech-to-text and TTS (MP-R5) | `VOX` #36 | `src/lib/aiur/eleven_labs.ex`, `src/lib/aiur/eleven_labs/**`, `src/lib/aiur/voice.ex`, `src/lib/aiur/voice/**`, `src/lib/aiur_web/sockets/voice.ex`, `src/lib/aiur_web/voice*.ex` | `Aiur.Voice` (`Transcriber`, `Synthesizer`; messages `{:voice_transcript, :voice_error, :voice_closed}`, RC-14), channels `voice:dictate` and `voice:converse`; **registers** `AiurWeb.Sockets.Voice` (`/voice`) | config, web-kit | — | `elevenlabs.*`, `ELEVENLABS_API_KEY` | optional | package (MP-R5 owns) |
| `voice-conversation` | Conversational voice assistant (MP-E6, new). **2026-10-09:** split into a standalone core and an aiur adapter ([MP-E6 plan §17](https://github.com/aiur-team/aiur/blob/de341053cc16d2e6096a3a0d0fbacb43ef9f6eb0/docs/research/aiur-mobile-and-platform/bucket-2-platform/MP-E6/plan.md)) | none | — (no current source paths) | core: `VoiceConverse` session API, `VoiceConverse.Wire`, ports `BriefingSource`, `AgentChannel` (`ask`, `instruct`, `fork_query`), `CommandSource`, `Credentials`, `child_spec/1`; adapter: implements the ports over the status card, E7, E2, MP-R5 and MP-R7 `fork_session` | adapter: voice-conversation-core, config, listener-modes (every send, voice V7) | adapter: commands, conversations, executor-attention, harness-adapters (`fork_session`), voice-stt (ElevenLabs key via MP-R5) | `voice.conversation.*` (RC-13) owned by the adapter; the core takes a `%VoiceConverse.Config{}` struct and an injected transcript root | optional | core: standalone in-repo Mix project **born as a package** (MP-R1-KD4 precedent), path dependency of `src/`; Hex publish after the §5 criterion-1 check (MP-E6-C11-T07, E6-OQ16). Adapter: stays in `src/` |
| `pairing-discovery` | Machine pairing and instance registry, instance side (MP-N2, new) | none | — (no current source paths) | (MP-N2 owns); **registers** its device routes through web-kit route modules; reads the `machine-gateway` store library | identity, machine-gateway, web-kit | — | device credentials (MP-N2); `~/.aiur/machine` sections `mobile`, `gateway`, `pairing`, `transport` (RC-03) | optional | package |
| `push-relay` | Encrypted notification relay client (MP-N4, new) | none | — (no current source paths) | (MP-N4 owns) | identity, pairing-discovery, event-bus, commands | build-orders (root progress via `Aiur.BuildProgress`, RC-40), build-queue (queue progress) | relay provider config (MP-N4/MP-R4); `~/.aiur/machine` section `push` | optional | package; the relay service is the separate `relay-service` row |
| `streamdeck-server` | Daemon side of the Stream Deck (MP-R6) | `SD` #35 (server half) | `src/lib/aiur_web/controllers/streamdeck*.ex`, `src/lib/aiur_web/routes/streamdeck.ex`, `src/lib/aiur_web/sockets/streamdeck.ex`, `src/lib/aiur_web/stream_deck_grid.ex`, `src/lib/aiur_web/streamdeck*.ex`, `src/lib/aiur_web/streamdeck_channel/*.ex`, `src/lib/aiur_web/streamdeck_logs/*.ex`, `src/lib/aiur_web/streamdeck_projection/*.ex` | `streamdeck:fleet` channel; **registers** `AiurWeb.Routes.Streamdeck` (`POST /api/v1/streamdeck/token`) and `AiurWeb.Sockets.Streamdeck` | web-kit, conversations, commands, projections | voice-stt | `AIUR_PHOENIX_URL` is sidecar-side | optional | stays beside web (prior #35) |

#### Planned L3 components (`status: planned`; rows exist so C10 `features[].adds` can name them)

| ID | Component | added_by | Paths (proposed) | Facade / public interface | Req | Opt | Owns config / state | Kind | Target |
|---|---|---|---|---|---|---|---|---|---|
| `machine-gateway` | Machine gateway process and the `aiur_machine` store library (MP-N2) | MP-N2 | — (no current source paths) | `Machine.Store` (`device_active?/1`, `sign/2` with purpose `:qr|:registry|:push`), `Machine.Store.Watcher`, gateway HTTP (`/v1/token`, pairing); works with `--no-dashboard` | kernel, identity | — | `~/.config/aiur/machine/` (`machine_key`, `devices.json`, `pairing.json`); `~/.aiur/machine` sections `gateway`, `pairing`, `transport` | optional | package `aiur_machine` |
| `notification-policy` | Notification policy and per-device preferences store (MP-N5) | MP-N5 | — (no current source paths) | policy evaluation over bus topics; preferences read/write through the gateway's single writer | event-bus, identity, commands, push-relay | build-orders (root progress, capability `build_orders`, RC-40), build-queue (queue progress, capability `build_queue`) | preferences store; `~/.aiur/machine` section `notifications` | optional | package |

### L4 — Surfaces

| ID | Component | Prior | Paths today | Facade / public interface | Req | Opt | Owns config / state | Kind | Target |
|---|---|---|---|---|---|---|---|---|---|
| `web-shell` | HTTP endpoint, router, auth, sockets, JSON API | part of `WEB` #34 | `src/lib/aiur/http_server.ex`, `src/lib/aiur/http_server/**`, `src/lib/aiur/tailscale_funnel.ex`, `src/lib/aiur_web/controllers/*api*.ex`, `src/lib/aiur_web/controllers/observability*.ex`, `src/lib/aiur_web/endpoint.ex`, `src/lib/aiur_web/endpoint_config.ex`, `src/lib/aiur_web/financial_data_access.ex`, `src/lib/aiur_web/router.ex`, `src/lib/aiur_web/routes/api.ex`, `src/lib/aiur_web/supervisor_auth.ex` | `/api/v1/*` JSON, Phoenix sockets `/live` `/streamdeck` `/voice` (`endpoint.ex:14-27`); **route and socket registration seam** (MP-R1-C6-T01/T02, RC-39): it composes each component's `AiurWeb.Routes.*` and `AiurWeb.Sockets.*` module in a fixed order | config, identity, projections, web-kit | the registering components (identity, github-listeners, commands, build-orders, voice-stt, pairing-discovery, streamdeck-server, dashboard-ui): downward composition edges, not allowlisted | `server.*`, `observability.*`, `AIUR_DASHBOARD_USERNAME/PASSWORD` | optional (every remote client needs it) | package `aiur_web_shell` |
| `dashboard-ui` | LiveView pages and Operator Control Center | rest of `WEB` #34 | `src/lib/aiur/event_humanizer.ex`, `src/lib/aiur/event_humanizer_helpers.ex`, `src/lib/aiur/post_deploy_checklist.ex`, `src/lib/aiur_web/**`, `src/lib/aiur_web/routes/dashboard_pages.ex`, `src/lib/aiur_web/sockets/live_view.ex` | **registers** `AiurWeb.Routes.DashboardPages` and `AiurWeb.Sockets.LiveView` (routes `/`, `/chat/...`, `/commands`, `/analytics`, `router.ex:133-151`) | web-shell, projections | commands, build-orders, conversations, voice-stt, accounting, streamdeck-server (`streamdeck_live.ex` uses its `StreamdeckLogs`/`StreamdeckProjection`, X-43) | none beyond `observability.dashboard_writable` | optional | package `aiur_web` |
| `tui` | tmux agent list, pane manager, opencode chat panes | `TUI` #33 + `OC` #24 | `src/lib/aiur/agent_list/**`, `src/lib/aiur/conversations.ex`, `src/lib/aiur/events/debug_log.ex`, `src/lib/aiur/opencode/**`, `src/lib/aiur/opencode_theme.ex`, `src/lib/aiur/pane_manager.ex`, `src/lib/aiur/pane_manager/**`, `src/lib/aiur/tmux.ex`, `src/lib/aiur/tmux/**` | interactive only | orchestration, projections, harness-adapters | — | `opencode.*` | optional | package `aiur_tui` |
| `control-cli` | Composition root, control RPC, per-component CLI verbs | `CLI` #31 | `src/lib/aiur.ex`, `src/lib/aiur/*_cli.ex`, `src/lib/aiur/affected_tests.ex`, `src/lib/aiur/affected_tests/**`, `src/lib/aiur/agent_control_cli_freshness.ex`, `src/lib/aiur/application/**`, `src/lib/aiur/cli.ex`, `src/lib/aiur/cli/**`, `src/lib/aiur/control_call.ex`, `src/lib/aiur/control_call/**`, `src/lib/aiur/control_cli/**`, `src/lib/aiur/daemon_lifecycle.ex`, `src/lib/aiur/distribution.ex`, `src/lib/aiur/external_content.ex`, `src/lib/aiur/findings.ex`, `src/lib/aiur/handoff/cli.ex`, `src/lib/aiur/id_floor_sources.ex`, `src/lib/aiur/launch_state_adoption.ex`, `src/lib/aiur/launcher_watchdog.ex`, `src/lib/aiur/pr_merge.ex`, `src/lib/aiur/pr_merge/checks.ex`, `src/lib/aiur/pr_merge/client.ex`, `src/lib/aiur/pr_merge/facts.ex`, `src/lib/aiur/pr_merge/gate.ex`, `src/lib/aiur/pr_merge/identity.ex`, `src/lib/aiur/pr_merge/merge_result.ex`, `src/lib/aiur/pr_merge/record.ex`, `src/lib/aiur/pr_merge/reviews.ex`, `src/lib/aiur/pr_merge/rules.ex`, `src/lib/aiur/pubsub_boot.ex`, `src/lib/aiur/shutdown.ex`, `src/lib/aiur/specs_check.ex`, `src/lib/aiur/test_http_guard.ex`, `src/lib/aiur/test_reset.ex`, `src/lib/aiur/test_reset/**`, `src/lib/aiur/test_shard.ex`, `src/lib/aiur/test_ticket_scope.ex`, `src/lib/mix/tasks/**` | versioned control protocol (later); each component registers verbs | all required components | all optional components | supervision order | required | core |
| `launcher` | Shared bash engine and `aiurdev` | #32 | `packaging/**`, `scripts/aiurdev` | CLI surface in `website/docs-app/reference/cli.md` | (wire) control-cli | — | instance records, tmux socket names | required | stays until the control surface is versioned |
| `init` | Init wizard and upgrade notice | `INI` #37 | `src/lib/aiur/init.ex`, `src/lib/aiur/init/**`, `src/lib/aiur/upgrade.ex`, `src/lib/aiur/upgrade/**` | `aiur init` | config, tracker | each component's setup section | `upgrade.*` | required | package `aiur_init` |

### L5 — Clients and non-runtime packages

| ID | Component | Paths | Depends on (wire only) | Kind | Target |
|---|---|---|---|---|---|
| `aiur-contracts` | Published wire contracts: JSON Schemas and generated TS types for identity, capabilities, events, Commands, conversations, notifications (new, MP-R1-C3; `status: planned` until C3-T06, `added_by: MP-R1`, exempt from rule I4) | `packages/aiur-contracts` (proposed) | `packages/aiur-contracts/**` | required | npm workspace package |
| `listener-spec` | Listener-mode spec package shared with Khala: JSON spec and golden fixtures (MP-E7, MP-Q1/E7-D1; RC-36). `status: planned`, `added_by: MP-E7` | vendored at build time into `src/priv/listener_spec/` with a pinned sha256 in `CHECKSUM` | — (no current source paths) | optional | published from Khala (E7-D1) |
| `relay-service` | Push relay service (MP-N4). `status: planned`, `added_by: MP-N4` | `services/push-relay-service` (proposed; inside MP-R1 acceptance 1 scope) | — (no current source paths) | optional | separate deployable service; self-hostable |
| `streamdeck-sidecar` | `@aiur/streamdeck` (MP-R6) | `packages/streamdeck` | `packages/streamdeck/**` | optional | repo candidate (prior #35, `ui-16`) |
| `mobile-app` | Phone app (MP-N1) | `packages/aiur-mobile` (proposed) | — (no current source paths) | optional | separate monorepo package (MP-R1-KD4) |
| `watch-apps` | Apple Watch and Android watch targets (MP-N7) | inside `packages/aiur-mobile` (RC-17) | — (no current source paths) | optional | inside the mobile package |
| `aiur-style` | Shared styles | `packages/aiur-style` | `packages/aiur-style/**` | optional | unchanged |
| `docs-site` | Docs site and the component directory page | `website/docs-app` | `website/docs-app/**` | required (docs gate) | stays with code (prior #40) |
| `skills` | `aiur-agent` and Executor skills | `.claude/skills/**`, `src/prompts/**` | `.claude/skills/**`, `packages/nightly-release/**`, `src/prompts/**` | required | prior #39 unchanged |

### Phase D assignments (contract requests)

- **event-bus** also owns the new bus modules: `events.ex`,
  `events/{delivery,history_store,trace,source_policy,trust_classifier,journal,durable_consumer,catalog,envelope}.ex`,
  `events/export/**`, and `Aiur.IdFloorSources` (CR-R2-1 c, d). `debug_log.ex` is
  **not** event-bus: after MP-R2-C2-T05 it is the default trace implementation and
  belongs to `tui` (CR-R2-1 a).
- **github-listeners** also owns `events/{sanitizer,branch_ref_store,comment_filter}.ex`,
  `Aiur.GitHub.EventTrust` and `Aiur.GitHub.EventSourcePolicy` (CR-R2-1 b, d).
- **agent-runner** also owns `event_publication_log.ex` and
  `Aiur.IssueLog.EventHistorySink`; **orchestration** owns
  `Aiur.Orchestrator.EventDelivery` (CR-R2-1 b, d).
- **kernel** owns the value types `tracker_identity.ex` (`Aiur.TrackerIdentity`) and
  `opaque_identifier.ex` (`Aiur.OpaqueIdentifier`). They are pure data, and
  `Aiur.TicketObservation` (event-bus, L1) needs them, so the upward
  `event-bus → tracker` edge is removed by reassignment, not allowlisted (CR-R2-2).
- **tracker** (`Aiur.Tracker`) gains five optional callbacks used by the queue:
  `open_issue_labels/1`, `blocked_by/1`, `issue_closure/1`, `ticket_pull_request/1`,
  `ensure_labels/1`. GitHub implements them; Linear answers `{:error, :unsupported}`
  (CR-E1-3). No new component edge beyond RC-11's two.
- **build-orders** owns `Aiur.BuildProgress` (`src/lib/aiur/build_progress.ex`) and
  `Aiur.BuildOrder.ProgressObserver` (`build_order/progress_observer.ex`), which writes
  into it (RC-40, which supersedes the earlier build-queue assignment). MP-E1-C7 still
  writes the code; the queue is one producer. MP-N5's build-order notifications check
  `build_orders`, so D18's defaults work without the queue (CR-E1-4, RC-10).
- **commands**: answer delivery stays a **synchronous call** through a
  delivery-target port that orchestration implements (MP-R1-C8-T02); the existing
  `decision.answered` event only wakes the orchestrator. `commands` is **required**,
  because the dispatch gate fails closed when the store is unreadable (CR-C8-3). The
  table row, migration step S10 and the capability matrix's minimum set say the same.
- **listener-modes** (RC-36): the send router is required core (`Aiur.Listener.*`).
  The Khala spec is the separate non-runtime `listener-spec` row, a build-time input.
  If the vendored spec is absent or fails its checksum, the router keeps today's
  routing (`:legacy`, RC-05) and reports `listener_modes` as `unavailable`
  (`not_installed` or `spec_invalid`). Orchestration implements
  `Aiur.Listener.DeliveryTarget`, so the router has no edge to orchestration.
- **web registration** (RC-39): no L1–L3 row lists `web-shell`. Each component owns
  its `AiurWeb.Routes.*` and `AiurWeb.Sockets.*` modules, built on `web-kit` only;
  `web-shell` composes them (MP-R1-C6-T01 owns the seam, C6-T02 the sockets). Its
  references to those modules are downward Opt edges.
- **Kind** is binary (`required` or `optional`) in every row, the checker's enum
  (MP-R1-C1-T01). Parenthesised text is a note, not a third kind.
- **conversations**: the read facade is `Aiur.Conversation.History` (not
  `Aiur.Conversations`, which is the existing tmux pane facade); the journal write side
  sits at the agent-runner layer (conversations contract §6, CR-C8-1).

## 4. The build-queue seam (MP-E1 ships first)

MP-E1 lands before this refactor (D2). It must be built so that R1 moves it without
rewriting it. These are the seam rules R1 imposes; MP-E1 owns the design behind them.

| Rule | Reason | How it is checked |
|---|---|---|
| All code under `src/lib/aiur/build_queue/`; one facade module `Aiur.BuildQueue` | One move later | manifest entry `build-queue` from day one |
| No reference to `Aiur.Orchestrator` or its sub-modules, and no read of `Orchestrator.State` | Prior #12: the orchestrator is the largest knot; D4 leaves capacity to the dispatcher | dependency check (or, before MP-R1-C1 exists, a dedicated ExUnit source-scan test shipped with E1) |
| Readiness is written only through the `Aiur.Tracker` contract (`add_label/2`, `remove_label/2`, `tracker.ex:26-27`), never `Aiur.GitHub.*` | Keeps the queue tracker-neutral; the prior survey counts 64 modules that bypass this | same check |
| Inputs arrive as bus events (`ticket.<id>.pr.merged`, issue state changes), subscribed through `Aiur.Events.Exchange` | Survives the R2 move unchanged | same check |
| Dependency data comes from a `DependencySource` behaviour. A `BuildOrder` implementation is the **only** module allowed to reference `Aiur.BuildOrder.*`; it is chosen at runtime when capability `build_orders` is available. The ad-hoc list ("after #N", D5) is a second implementation | D5: optional build-order dependency | same check; test with the build-order source absent |
| Attention is raised through one local function that calls `Aiur.Alerts` today | Becomes `Signal.alert/2` after the signal port lands (plan-refresh row PR-07) | review |
| Own config section module and own `Config.Paths` key | Schema registration later (MP-R1-C4) | `check-config-docs.py` already gates the docs entry |
| Registers capability `build_queue` (and `build_queue.build_order_source`) through a provider once MP-R1-C3-T01 exists (MP-E1-C3-T08) | Clients detect it | contract test |
| Orchestration reaches the queue only through `Hints` (read) and implements `ClaimProbe` (RC-11, MP-E1 X-1) | D3 ordering and D8 race-free withdrawal need them | manifest `seams` (MP-R1-C1-T06); until then MP-E1's scan test |

Baseline fact supporting the seam: no module under `src/lib/aiur/orchestrator/`
references `Aiur.BuildOrder` at `45a290e3` (`git grep -l 'Aiur.BuildOrder' -- src/lib/aiur/orchestrator`
is empty), so build-order data already reaches dispatch only through labels and
`blocked_by` edges.

## 5. Config ownership

Today one root schema embeds 20 sections (`src/lib/aiur/config/schema.ex:52-71`), and
sections validate by calling feature modules (prior #2). Target: each component
registers its own section module, its validator, its `Config.Paths` keys and its
environment variables. The root keeps only `tracker`, `server`, `observability` and
the registry. The `.aiur/config` file format does not change; only who defines each
key changes. `scripts/check-config-docs.py` keeps walking `embeds_one` from the root,
so registration must keep the sections reachable from `Aiur.Config.Schema` (see
MP-R1-C4 risks).

| Section (`schema.ex` line) | Owner component |
|---|---|
| `tracker` (52) | tracker (+ `github`/`linear` subsections) |
| `polling` (53) | github-listeners (GitHub cadences), orchestration (poll cycle) |
| `workspace` (54), `hooks` (58), `prewarm` (64) | workspace |
| `worker` (55) | orchestration |
| `agent` (56) | harness-adapters (routing, backends), orchestration (concurrency, load governor) |
| `decisions` (57) | commands |
| `monitoring` (59) | telemetry |
| `observability` (60), `server` (61) | web-shell |
| `opencode` (62) | tui |
| `events` (63) | event-bus |
| `alerts` (65) | executor-attention |
| `pr_health` (66), `pr_watch` (67) | orchestration (PR lifecycle) |
| `build_order` (68) | build-orders |
| `webhooks` (69) | github-listeners |
| `elevenlabs` (70) | voice-stt |
| `upgrade` (71) | init |
| `build_queue` (proposed) | build-queue |
| `voice.conversation` (proposed, RC-13) | voice-conversation |

Phase C (MP-R1-C4-T05, RQ4): sections stay literal `embeds_one` lines in the root schema,
because Ecto composes the struct at compile time and `check-config-docs.py` reads those
lines. Ownership is manifest data (`owns.config`, exactly one owner per section;
`polling` → orchestration and `agent` → harness-adapters, with `shared_with` noting the
split above). Behavioural coupling is removed by C4-T01..T04 (registered semantic checks,
turn-sandbox root contributors, accessor moves, env checks).

Phase C placements for modules the prior survey did not map (RQ5, measured with the
prior walker at `45a290e3`): `Aiur.Muse.*`, `Aiur.AgentTools.*` → harness-adapters;
`Aiur.AllowedContributors*` → github (it references `Aiur.GitHub.*` 10 times and is
referenced by `GitHub.Issues`, `Events.GithubWebhook`, `Config.Schema.Github`);
`Aiur.DaemonHeartbeat*` → telemetry; `Aiur.AgentContextPresentation` → agent-runner;
`Aiur.TestTicketScope` → control-cli; `Aiur.GlobalConfigStartup` → github (C4-T04);
`Aiur.Perf`, `Aiur.LogFile` → signal (C5-T04); `Aiur.Protocol.MapAccess`,
`Aiur.CoordinationTasks`, PROPOSED `Aiur.Journal`, `Aiur.Bounded`, `Aiur.ProcessTree` →
kernel (C5-T01, C5-T02).

`~/.aiur/config` is the fallback **workflow** config (`workflow.ex:84-93`), not machine
config. Machine-level settings live in the new `~/.aiur/machine` file (RC-03): sections
`mobile`, `gateway`, `pairing` and `transport` are owned by `machine-gateway` /
`pairing-discovery` (MP-N2), `push` by `push-relay` (MP-N4) and `notifications` by
`notification-policy` (MP-N5). `~/.config/aiur/machine/identity.json` is owned by
`identity` (machine id), the rest of `~/.config/aiur/machine/` by `machine-gateway`, and
the cookie and instance records by `launcher`. `~/.aiur/.env` keeps its current
precedence. Secrets stay in their current places; no component reads another
component's secret (brief §7).
