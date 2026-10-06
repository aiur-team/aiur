---
feature_id: MP-R2
doc: producer/consumer inventory
base_main_sha: 45a290e3
date: 2026-10-06
method: read-only `git show 45a290e3:<path>` and `git grep 45a290e3`; two parallel code surveys plus direct re-reads of every load-bearing line (marked [re-verified])
---

# MP-R2 inventory: every producer and consumer of the event paths

Paths are relative to `src/lib/` unless they start with `src/`, `website/`,
`packaging/` or `.claude/`. "Uncertain" marks a claim the surveys could not
close; each has a research question in [plan.md](plan.md) §9.

## 1. Exchange core (`aiur/events/`)

| Module | Lines | Role | Key evidence |
| --- | --- | --- | --- |
| `Events.Exchange` | 221 | ETS `:duplicate_bag` of `{pattern, pid, ref}`; `publish/3` folds the table and `send(pid, {:event, e})` **in the caller's process**; GenServer only serializes subscribe/unsubscribe and reaps on `:DOWN`; table registered in `persistent_term` | `exchange.ex:93-108,129-176` [re-verified] |
| `Events.Topic` | 91 | AMQP-style `*` / `#` matcher; also used by `Aiur.Alerts` | `topic_test.exs` |
| `Events.Publisher` | 539 | Single publish boundary; gates in order: durable-decision topic refused → GitHub-sourced `executor.*` refused → bot self-loop `:filtered` → untracked issue `:filtered` → `ResourceStore.processed?` `:deduped` → 1 h ETS window `:deduped`; then `do_publish`: `IdGenerator.next_id` → build event → `Exchange.publish` → IssueLog marker → `mark_resource_processed` → `DebugLog` | `publisher.ex:113-122,188-234` [re-verified] |
| `Publisher.publish_persisted/4` | — | Caller supplies a durable id; skips all gates but the executor/GitHub check; same fan-out | `publisher.ex:257-271` [re-verified] |
| `Events.IdGenerator` | 365 | Per-instance monotonic id, reserve-before-return batches of 50, `event-id.json` in the runtime state dir, gaps allowed, `next_id` is a GenServer call | `id_generator.ex:1-85` [re-verified] |
| `Events.SubscriptionStore` (+ supervisor, registry) | 748 + 21 | One GenServer per running ticket; persisted bindings, `last_seen_event_id`, open attentions; delivers via `GenServer.call(Orchestrator, {:enqueue_event_digest, …})` (injectable `set_enqueue_fn/1`); drop `id <= cursor`; stall/buffer/retry ×3 then dead-letter alert | `subscription_store.ex:257-261,385-498` [re-verified] |
| `Events.UniversalSubscriptions` | 144 | Bindings every ticket gets (own comments, reviews, CI, progress request, base-branch push, base-branch changed) | `universal_subscriptions.ex:31-32` |
| `Events.AgentSubscriptionPolicy` | 32 | Agent manual subscriptions must name one literal ticket | message-bus.md:59-70 |
| `Events.Sanitizer` | 393 | Payload sanitization; calls `CodeOwners` (prior boundary finding: replace with a trust-classifier callback) | prior `feature-boundaries.md` #10 |
| `Events.BranchRefStore` | 465 | Ticket branch ref state for ls-remote (prior: move to ING) | prior #10 |
| `Events.DebugLog` | 121 | PubSub mirror `aiur:events:debug[:<id>]` via `local_broadcast`, carries the event id | `debug_log.ex:82,93` |
| `Aiur.TicketObservation` | 223 | v1 envelope attached to every event; `:joinable` only with a trusted `TrackerIdentity` | `ticket_observation.ex:36-71` [re-verified] |
| `Aiur.EventPublicationLog` | 62 | Write-only, fsynced per-launch log of agent `emit_event` outcomes; nothing in the daemon reads it | baseline R2 |
| `Webhooks.EventSource` | — | Calls `Exchange.publish` directly, bypassing Publisher; no production caller found (uncertain; RQ-6) | `webhooks/event_source.ex:51-58` |

Supervision: `IdGenerator`, `Exchange`, `Publisher` start in that order inside
a `:rest_for_one` tree (`aiur.ex:118,358-374`); `DecisionStore`
(`:407`), subscription registry/supervisor (`:415-416`), `TicketActivity`
(`:429`) and `Orchestrator` (`:442`) follow. Executor recording children
(`Claims`, `ExecutorWakeInbox`, `ExecutorListener`) start after the Exchange
whenever recording is on (`aiur.ex:455-463,503`). An Exchange crash drops
all bindings; everything after it restarts and re-binds.

## 2. Producers (Exchange)

### 2.1 `ticket.*`

| Topic template | Producer | Durability today |
| --- | --- | --- |
| `ticket.<n>.branch.push`, `system.<branch>.branch.push` | `events/ls_remote_ticker.ex:183,197,205` (topic: `github_keys.ex:23-30`) | live |
| `ticket.<n>.branch.push`, `.pr.opened`, `.pr.ready_for_review`, `.pr.merged` | `events/github_firehose.ex:358,370-422` (pre-boot events dropped, `:306-329`) | live |
| `ticket.<n>.issue.commented`, `.pr.review_comment`, PR topics | `events/github_webhook.ex:244,249`; topics `github_webhook/normalizer.ex:394,416,449,645-647`; `issues`/`pull_request`/`check_*` call `Orchestrator.request_refresh/0`; `sub_issues`/`issue_dependencies` only deposit to ResourceStore | live |
| `ticket.<n>.pr.review_comment`, `.issue.commented` | `events/github_comments_poller.ex:697,712,726,743,798` | live |
| `ticket.<n>.pr.review_comment` | `orchestrator/command_scan.ex:316` | live |
| `ticket.<n>.pr.ready_for_review` | `orchestrator/ready_for_review_transitions.ex:185` | live |
| `ticket.<n>.ci.passed` / `.ci.failed` | `orchestrator/ci_lifecycle.ex:338,361` (also enqueues digest directly, `:368`) | live |
| `ticket.<n>.pr.draft_approved_green[.resolved]`, `.pr.parked_ready[.resolved]` | `orchestrator/ci_lifecycle.ex:678,699,833,856` via Alerts | ledgered |
| `ticket.<n>.issue.opened.allowed_contributor` | `allowed_contributors/wake.ex:22,26` | live |
| `ticket.<id>.operator.progress_request` | `progress_checkin/worker.ex:90,102` | live |
| `ticket.<id>.agent.<name>` (agent `emit_event`) | `agent_runner/tool_executor.ex:394-462,478` (joinable identity `:441`) | logged |
| `ticket.<id>.agent.<name>` (agent alerts) | `agent_runner/tool_executor.ex:107-127` (joinable identity `:123`) | logged + ledgered |
| `ticket.<id>.agent.decision.<slug>` (answered, expired, mooted, deferred, queued, delivered, acknowledged, resolved…) | `decision_store.ex:2555-2558` (`publish_persisted`, durable id) | journaled (DecisionStore) |
| `ticket.<id>.agent.decision.requested` | `decision_store.ex:4604-4608` | journaled |
| `ticket.<id>.agent.attention.*` and other runtime alerts | `agent_runner/{model_label_refresh,session_lifecycle,turn_alerts,queue_drain}.ex`, `agent_runner.ex:297,314`, `decision_attention.ex:436,447`, `github/dispatch_authorization.ex:734`, `executor/takeover_alert/monitor.ex:269,279` | ledgered (unattributed, so not logged) |

Not events today (needed by MP-E1): PR closed without merge, issue
closed/reopened, `blocked_by` / sub-issue edge changes. They trigger
`Orchestrator.request_refresh/0` or a ResourceStore deposit only
(`github_firehose.ex:21,426-428`; `normalizer.ex:282-301`).

### 2.2 `system.*`

All via `Aiur.Alerts.emit_system/emit_custom` (`alerts.ex:104-119,293-331`)
unless noted, so `ledgered`:
`system.subscription_store.event_dead_lettered` (`subscription_store.ex:508`),
`system.github_app_token.*`, `system.github.budget_broker_*`,
`system.github.connectivity_lost`, `system.github.budget_meter_disagreement`,
`system.github.quota.*`, plus injected `emit_system` callers
(`build_gate_hold_monitor.ex:84`, `daemon_heartbeat_checker.ex:30`,
`decision_attention_signals.ex:155`, `executor_command_attention.ex:102,113`,
`coding_agent/route_failure.ex:112`). `system.<branch>.branch.push` is `live`
(no alert). Producers of `system.dispatch.*`, `system.fleet.*`,
`system.tracker.*` and `system.config.base_branch.changed` were not traced
(they appear as bindings in `executor_bindings.ex:9-22` and
`universal_subscriptions.ex:32`); RQ-5.

### 2.3 `executor.*`

| Producer | Path |
| --- | --- |
| `aiur executor emit` | `agent_control_cli.ex:388` → `ExecutorEvents.publish(…, source: :executor_cli)` |
| `executor.decision.requested` | `ExecutorEvents.publish_requested` injected into DecisionStore (`decision_store.ex:584`); boot reconciliation `ensure_requested`/`reconcile_requested` (`:583,585`) |
| `executor.decision.deferred` | `decision_store.ex:2625`; dashboard "Notify Executor again" `aiur_web/operator_control_center/decision_commands.ex:231` (`renotify: true` → fresh id, same `decision_id`, `executor_events.ex:28-55`) |
| `executor.command.{requested,deferred}` | Alerts emitted by `ExecutorListener` (`executor_listener.ex:193-210`); ledgered, **not** journaled |

`ExecutorEvents.publish/3`: validate topic → reject GitHub source →
`reserve_durable_id` → JSON-normalize → `append_event` (DecisionLog journal)
→ `publish_persisted` (`executor_events.ex:64-75,448-452`) [re-verified].

### 2.4 `decision.*`

Bare or suffixed `decision.requested|acknowledged|resolved` are refused by
`publish/3` (`publisher.ex:57,285`) and by the agent tool
(`tool_executor.ex:488`); agent acknowledge/resolve go to the DecisionStore
recorder (`tool_executor.ex:390`). All Command traffic on the bus is
`ticket.<id>.agent.decision.*` or `executor.decision.*`.

## 3. Consumers (Exchange)

| Consumer | Binding (file:line) | Patterns | Action |
| --- | --- | --- | --- |
| `SubscriptionStore` ×N | `subscription_store.ex:304,564,671` | per-ticket list + universal | enqueue digest to Orchestrator → `IssueLog.record_event(:consumed)` → cursor |
| `Orchestrator.Lifecycle` | `orchestrator/lifecycle.ex:32-43,408-410` | 9 `ticket.*` patterns + `system.*.branch.push` [re-verified] | `orchestrator/event_topics.ex:9-57`: comment wake, mark merged, CI resume, pause, decision-answered wake, unblock, blocker push, base push |
| `ExecutorListener` | `executor_listener.ex:52,80,116` | `ExecutorBindings.patterns()` (27, `executor_bindings.ex:7-36`) | `executor.*`: watermark, scrub, Command alert; others: `ExecutorWakeProjection.project` → `ExecutorWakeInbox.enqueue` |
| `ExecutorEvents.listen` (CLI) | `executor_events.ex:121-140` | persisted executor subscriptions | prints JSON lines; cursor for `executor.*` only |
| `DecisionMetrics` | `decision_metrics.ex:21,64,129` | `ticket.*.agent.decision.#`, `ticket.*.agent.attention.#` | latency metrics → PubSub `:decision_metrics_changed` |
| `RunTelemetry.Writer` | `run_telemetry/writer.ex:32-37,412` | `pr.opened`, `pr.merged`, `issue.commented`, `pr.review_comment` | lifecycle NDJSON anchor |
| `TicketActivity` | `ticket_activity.ex:73,117` [re-verified] | `ticket.*.#` | projection; PubSub `ticket-activity:changed` |
| `BuildOrder.TicketHistoryProvider` | `build_order/ticket_history_provider_options.ex:37`; handler `ticket_history_provider.ex:142` | `ticket.*.#` | bounded history; PubSub `build_order:history:<b64>` |

## 4. Durable readers

| Reader | Path | Reads |
| --- | --- | --- |
| `IssueLog.event_history/2` | `issue_log.ex:143-200` | per-ticket event log; kinds default `[:emit, :emit_alert]`; `since_id`, `limit` (100) |
| `BootstrapDigest` | `agent_runner/bootstrap_digest.ex:74-92,106-126`; called `agent_runner.ex:400-401` | concrete `ticket.<id>` patterns only; `system.*` and wildcards skipped [re-verified] |
| `AgentEventFeed.bus_events/2` | `agent_event_feed.ex:107-111` | callers `aiur_web/streamdeck_logs.ex:635`, `aiur_web/live/streamdeck_live.ex:1466` |
| `AgentEventFeed.list/2` → `IssueLog.read_tail/2` | `agent_event_feed.ex:79-91` | **transcript**, byte-cursor paged; served by `GET /api/v1/:issue_identifier/events` (`router.ex:191`, `observability_api_controller.ex:38-45`). Despite the route name it returns transcript messages, not bus events [re-verified] |
| `TicketHistoryProvider` | default `history_fun` `&IssueLog.event_history/2` (`ticket_history_provider_options.ex:34`) | identity form |
| `ExecutorEvents.replay/2` | `executor_events.ex:143-154`; callers `:129`, `executor_listener.ex:134` | executor journal by pattern and cursor |

IssueLog persistence gate [re-verified]: `record_event/3` writes only when the
event's `TicketObservation` is `:joinable`, its identity matches the topic's
ticket, and a writer is registered (`issue_log.ex:545-560,573-581,616`).
Writers exist only for issues attached since BEAM start
(`issue_log.ex:1-13`). Result: GitHub, CI, PR, Command and orchestrator
events are delivered live but never written to the per-ticket log
(survey inference from code; witness ticket MP-R2-C1-T01).

## 5. Executor journal and wake inbox

Files under `~/.aiur/repo/<owner>/<repo>/executor/` (`executor/state_paths.ex:23-29,89`):
`<repo>.executor.events.ndjson` (journal), `.executor.wakes.ndjson`,
`.executor.wakes.cursor.json`, `.executor.wakes.pending.json`,
`.executor.subscriptions.json`, `.executor.listener.watermark.json`,
`.executor.claims.json`.

- `ExecutorWakeProjection.project/1` reduces any non-`executor.*` event to
  identifiers and enums (`executor_wake_projection.ex:8-40`).
- `ExecutorWakeInbox` merges by `{topic_class, ticket}`, assigns its **own**
  `wake_id` sequence (`executor_wake_inbox.ex:135-149`; the projected
  `wake_id = event_id` is overwritten), keeps `event_id`, debounces 2 s from
  the first unflushed record, caps at 10 000, persists pending before flush,
  and advances the cursor only through the lease-checked `acknowledge_as/3`
  (`:31-61`).
- Gap: non-`executor.*` events published while `ExecutorListener` is not bound
  are lost; the watermark covers `executor.*` only (`executor_listener.ex:144-178`).
  Prior evidence of backlog size: `refactor-2026-09-26/synthesis/wake-consumption-audit.json`.

## 6. Phoenix PubSub (`Aiur.PubSub`)

50 topic shapes; 31 files broadcast directly (+~31 via wrappers); 34 files
subscribe directly (+~35 via wrappers). Only the `DebugLog` mirror carries an
`IdGenerator` id; no PubSub topic is replayable. Started by
`Aiur.PubSub.Boot` at `aiur.ex:302`.

| Family | Topics (owner wrapper) | Kind of fact |
| --- | --- | --- |
| Agent | `agent:<id>` transcript/alert/control/turn messages; `agents:chat_active`, `agents:running`, `agents:status`, `orchestrator:poll_state`, `prewarm:phase` (`AgentPubSub`, payloads `AgentEvents`) | live stream + runtime state |
| Decisions | `decisions:changed` `{:decision_changed, id, version}` / `:decision_metrics_changed`; `decisions:dispatches_reconciled` (no lib subscriber) (`DecisionPubSub`) | invalidation with version |
| Observability | `observability:dashboard` `{:observability_updated, unique_int}` (`ObservabilityPubSub`); `observability:financial:<gen>:<gen>` | invalidation |
| Current run | `current-run-membership:changed`, `current-run-summary:changed`, `current-run-outcomes:changed`, `ticket-activity:changed`, `open_tickets:changed`, `live-conversation:changed:v<N>:{source,handle}:*`, `live-conversation:restarted` | invalidation with generation/epoch |
| Build order | `build_order:adhoc:changed`, `build-order-pack-status:changed`, `build_order:graph:{catalog,selected}:<b64>`, `build_order:graph:reset`, `build_order:detail:<b64>`, `build_order:ticket_detail_coordinator:reset`, `build_order:history:<b64>`, `build_order:ticket_history:reset` | snapshot + reset epoch |
| GitHub/config | `github:resource:<type>[:<repo>[:<id>]]`, `github:budget:lease_release` (test-only subscriber), `view_state:diverged`, `webhooks:mode:{degraded,recovered}`, `webhooks:delivery_mode:changed`, `workflow_store:configuration` | invalidation |
| Usage/meters | `usage-aggregate:changed`, `provider_meters:observed`, `provider_meters:<p>:<b>:<gen>`, `provider_meters:host_observed`, `provider-account-generation:<rand>`, `claude_telemetry:{events,usage}` | invalidation |
| Runtime/debug | `claude_hook:<id>`, `opencode:slots`, `attach_pool`, `aiur:perf`, `aiur:events:debug[:<id>]`, `streamdeck:fixture` (test fixture) | plumbing |

Exchange → PubSub bridges: `TicketActivity`, `TicketHistoryProvider`,
`DecisionMetrics`. Dual writers: `DecisionStore` (Exchange then
`decisions:changed`, `decision_store.ex:2558,2572,4608,4616`), `Alerts`
(Exchange, `agent:<id>` alert, `observability:dashboard`,
`alerts.ex:191-197,307,347`). No PubSub → Exchange bridge.

Incidental findings (not MP-R2 scope; report to owners):
`CurrentRunProjections` handles bare `:observability_updated` but
`ObservabilityPubSub` broadcasts `{:observability_updated, id}`, so the
projection ignores it (`current_run_projections.ex:145-146`,
`observability_pubsub.ex:20-21`) [re-verified]; ten topics have no
`src/lib` subscriber.

## 7. Stream Deck channel (`aiur_web/streamdeck_channel.ex`, 609 lines)

- Transport: `POST /api/v1/streamdeck/token` (basic auth, `router.ex:183`) →
  socket `/streamdeck` (`endpoint.ex:19`) → channel `streamdeck:fleet`.
- On join subscribes to PubSub only: `agents:running`, `agents:status`,
  `provider_meters:observed`, `decisions:changed`, financial config
  (`streamdeck_channel.ex:30-34`), then pushes a full `snapshot`
  (`:36,233-235`). It never subscribes to the Exchange.
- Pattern: **snapshot on join + PubSub invalidations → re-projected pushes**
  (`fleet`, `usage`, `decisions`, `commands`, `transcript`, `logs`, `alert`,
  `control`, `voice*`). No cursor, no replay; reconnect = new snapshot.
- Event→log association is daemon-side in `AiurWeb.StreamdeckLogs`
  (`bus_events` + transcript, timestamp-attached), the input MP-E4/MP-R6 reuse.
- Command answers go through `DecisionStore.answer/5` (`:570-573`), never the bus.
