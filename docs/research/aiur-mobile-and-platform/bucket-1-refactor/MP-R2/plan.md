---
artifact_contract: ce-unified-plan/v1
artifact_readiness: ticketed (Phase C, 2026-10-06); implementation blocked on DESIGN-R2
feature_id: MP-R2
bucket: 1 (refactor); C5-C7 tagged Bucket-2-enabling (RC-09)
base_main_sha: 45a290e3
date: 2026-10-06
owner_gate: ../../owner-design-tasks/DESIGN-R2.md
owned_contracts: ../../contracts/events-and-replay.md
prior_units: U3 (event and claim ordering), U7 (package seams), U8 (size)
prior_boundaries: BUS (#10), signal port (#11), EXE (#26), DEC (#27), PRJ (#28), ING (#9), ORC (#12), K (#1)
companion_docs: inventory.md, chunks.md
---

# MP-R2 — Standalone shared event bus: feature plan

## 1. Goal capsule

- **Objective.** Make the existing topic exchange a reusable component
  (`aiur_events`, prior boundary `BUS` #10) with the same behaviour, and write
  the contract that Commands (MP-E2), queue readiness and progress (MP-E1,
  MP-N5), event→conversation navigation (MP-E4) and push (MP-N4) build on.
- **Resolves** MP-Q5 ("which bus owns which facts"): see
  [contract §2](../../contracts/events-and-replay.md#2-which-channel-owns-which-fact-resolves-mp-q5).
- **Does not** add a broker, make the bus durable by fiat, rename topics, or
  change any user-visible behaviour in the packaging chunks.
- **Blockers.** DESIGN-R2 (owner gate); prior unit U3's event-delivery fix
  before C2-T01; prior unit U5 before C2-T02 (RC-21); MP-R1-C1 (manifest and
  checker) before C2-T11/C4; MP-R1-C2 (identity) before C5-T04; MP-N2-C6/C7
  before C7-T05. The package-layout, identity-owner and reclassification
  questions are settled (§12).
- **Tickets:** [tickets/README.md](tickets/README.md).

## 2. Repository findings (extends baseline §R2; full catalogue in [inventory.md](inventory.md))

The baseline R2 section is accurate except where F1 and F4 correct it.

| # | Finding | Evidence (`45a290e3`) | Consequence |
| --- | --- | --- | --- |
| F1 | **The per-ticket IssueLog is not a general event log.** `record_event/3` writes only for events whose `TicketObservation` is `:joinable` with a matching identity *and* whose ticket has a registered writer. Only agent `emit_event`/agent-alert paths pass a trusted identity. GitHub, CI, PR, Command and orchestrator events are delivered live and never written. | `issue_log.ex:545-560,573-581,616`; `publisher.ex:337-357`; `tool_executor.ex:123,441`; writer lifetime `issue_log.ex:1-13` | Baseline's "de facto durable per-ticket event log" holds for agent events only. Agent restart replay (`BootstrapDigest`) misses merges, CI and comments published while the agent was down. MP-E4 jump points for commits/merges have no durable source today. |
| F2 | **Event id order is not delivery order.** `publish/3` runs in the caller: id from a GenServer call, then `send/2` from the caller. Durable publishers reserve the id, fsync a journal, then publish. | `publisher.ex:113-122,220-234`; `id_generator.ex:83-85`; `exchange.ex:93-108`; `executor_events.ex:64-75` | Max-id cursors (`subscription_store.ex:397-400`, `executor_listener.ex:169-178`) can drop a late lower id. Source-reachable hypothesis; witness MP-R2-C1-T02. |
| F3 | Prior U3 stall-reorder finding is still present. | `subscription_store.ex:484-492` (`resolve_stall/2` self-sends behind newer mail) | Fix stays with U3 (`events-webhooks-executor-01`); C2 must not move the file before or without that ticket's witness. |
| F4 | `GET /api/v1/:issue_identifier/events` exists but returns the **transcript** (`AgentEventFeed.list` → `IssueLog.read_tail`), not bus events. | `router.ex:191`; `observability_api_controller.ex:38-45`; `agent_event_feed.ex:21-35,79-91` | There is still no external bus API. The name must not be reused for the feed; the proposed feed is `GET /api/v1/events` (no `:issue_identifier`), which the router's `:issue_identifier` routes would shadow unless ordered first (C7). |
| F5 | The wake inbox has its own `wake_id` sequence; the listener only watermarks `executor.*`. Non-`executor.*` wakes published while the listener is unbound are lost. | `executor_wake_inbox.ex:135-149`; `executor_listener.ex:144-178` | The Executor path already distinguishes journaled (`executor.*`) from live (wakes) facts; the contract's durability classes describe it rather than invent it. |
| F6 | PubSub carries 50 topic shapes of a different kind (invalidation, live streams, plumbing). Only the debug mirror carries an event id; nothing is replayable. Three Exchange→PubSub bridges, no reverse bridge. | inventory §6 | MP-Q5 answer: two buses with a placement rule, not one bus. |
| F7 | The Stream Deck channel is a client that never touches the Exchange: snapshot on join, PubSub invalidations, re-projected pushes. | `streamdeck_channel.ex:30-36,233-301` | Proven reconnect pattern (snapshot + invalidation) for remote clients; the external feed reuses it and adds a cursor. |
| F8 | Facts MP-E1 needs are not events: PR closed unmerged, issue closed/reopened, `blocked_by`/sub-issue edge changes. They call `Orchestrator.request_refresh/0` or deposit to ResourceStore. | `github_firehose.ex:21,426-428`; `normalizer.ex:282-301` | E1 must reconcile from tracker/graph state; adding these topics is E1's (Bucket 2) work. |
| F9 | Build-order progress exists only as PubSub graph snapshots. | `build_order/graph_projection.ex:1502-1518`, `pack_status.ex:228` | MP-N5's "every 25%" needs a new Exchange producer owned by build orders. |
| F10 | `IdGenerator → Exchange → Publisher` start in that order under `:rest_for_one`; an Exchange crash drops all bindings and restarts every later child, which re-binds. Executor recording children start after the Exchange. | `aiur.ex:118,358-374,455-463,503` | Packaging must keep this start order and the restart cascade (C4 acceptance test). |
| F11 | A config section `events.*` already exists (`block_state_debounce_seconds`, `custom_events_per_turn_max`, `codeowners_refresh_seconds`). | `config/schema/events.ex:7-11` | The bus owns `events.*`; `codeowners_refresh_seconds` belongs to the trust classifier (GHD). New keys go under `events.export.*`. |
| F12 | `Webhooks.EventSource.publish` would bypass `Publisher` (no id, no gates); no production caller found. | `webhooks/event_source.ex:51-58` | Delete or route through Publisher during C2 (RQ-6). |
| F13 | `Aiur.Alerts` is the largest `system.*` producer and a dual writer (Exchange, `agent:<id>`, `observability:dashboard`, three files). | `alerts.ex:191-197,245,293-331,347` | Prior signal port (#11) is the right seam; MP-R2 consumes it, MP-R1 owns it. |
| F14 | Incidental: `CurrentRunProjections` ignores `{:observability_updated, id}`. | `current_run_projections.ex:145-146`; `observability_pubsub.ex:20-21` | Report as a bug ticket to the WEB/PRJ owner; not R2 scope. |

## 3. MP-Q5 resolution (summary)

Two in-process buses stay, each with one job; the contract §2 table is the
authority:

- **Exchange** (`Aiur.Events.*`): coordination facts with identity, pattern
  routing, cursors, and (for some classes) replay. The only channel that may
  ever leave the daemon, through the export feed.
- **Phoenix PubSub** (`Aiur.PubSub`): "re-read X" invalidations with
  generations, live transcript streams, runtime plumbing. Never exported.
- **Durable stores** (DecisionStore, executor journal, wake inbox, webhook
  delivery log, alert ledger, IssueLog) are truth or audit, not buses.
- **Channels/LiveView** are clients. The **instance registry** is discovery.

The bus package owns the Exchange side and the placement rules (R-1..R-5); it
does not take ownership of PubSub topics, which stay with their features.

## 4. Proposed boundaries

### 4.1 Component `aiur_events` (prior `BUS` #10)

**Members (move as-is):** `Events.Exchange`, `Topic`, `Publisher`,
`IdGenerator`, `SubscriptionStore` (+ supervisor, registry),
`UniversalSubscriptions`, `AgentSubscriptionPolicy`, `DebugLog`,
`TicketObservation`, `EventPublicationLog`; the journal/cursor primitive used by
`ExecutorEvents` (C3); new in C5–C7: `Events.Catalog`, `Events.Envelope`,
`Events.Export` (exporter, journal, durable consumer), feed controller/channel
(web adapter lives in `aiur_web`, see 4.2).

**Moves out (prior #10 recommendations, kept):** `Orchestrator.EventTopics`
and `Orchestrator.AutoSubscriptions` → ORC; `BranchRefStore` → ING;
`Sanitizer`'s `CodeOwners` call → trust-classifier callback (GHD supplies it).

**Stays with its owner (MP-Q5 rule R-5):** `AgentPubSub`/`AgentEvents` (RUN),
`DecisionPubSub` (DEC), `ObservabilityPubSub` (WEB/PRJ), `ExecutorListener`,
`ExecutorWakeInbox`, `ExecutorWakeProjection`, `ExecutorBindings`, `Claims`
(EXE #26), `IssueLog` (RUN/conversation, MP-E4), `Aiur.PubSub.Boot` (kernel
app boot, MP-R1).

### 4.2 Public interface (behaviours and functions)

| Interface | Kind | Today's equivalent |
| --- | --- | --- |
| `Aiur.Events.publish(topic, payload, opts)` / `publish_persisted/4` | function | `Publisher.publish/3`, `publish_persisted/4` (unchanged return shapes) |
| `Aiur.Events.subscribe(pattern)` / `unsubscribe/1` / `bindings_for/1` | function | `Exchange.*` |
| `Aiur.Events.Delivery` | **behaviour** (sink for per-ticket subscription delivery) | replaces the hard `GenServer.call(Aiur.Orchestrator, …)` with a configured sink; default sink is the orchestrator adapter (`set_enqueue_fn/1` is today's test seam) |
| `Aiur.Events.Tracking` | **behaviour** (tracked-set predicate) | `tracked_fn` already injected (`publisher.ex:28-35`) |
| `Aiur.Events.TrustClassifier` | **behaviour** | `Sanitizer → CodeOwners` |
| `Aiur.Events.HistoryStore` | **behaviour** (append marker, `event_history(id, since_id:)`) | `IssueLog.record_event/3`, `event_history/2`; default implementation remains IssueLog |
| `Aiur.Events.Journal` | module (prepare/append/replay with corrupt-tail detection) | `DecisionLog` as used by `ExecutorEvents`/`ExecutorWakeInbox` (coordinate with MP-R1 kernel; prior "journal to kernel") |
| `Aiur.Events.Catalog`, `Envelope`, `Export`, `DurableConsumer` | new (C5–C6) | — |
| Web adapter: `EventsController`, `/events` socket + `events:feed` channel | new (C7), in `aiur_web` | pattern of `StreamdeckSocket`/`StreamdeckAuth` |

### 4.3 Dependencies

| Dependency | Required / optional | Why |
| --- | --- | --- |
| Kernel paths/JSON/journal (K, CFG) | required | state dirs, `event-id.json`, journals |
| Delivery sink (ORC) | optional at package level; required in the full product | the bus runs and routes without orchestration; per-ticket stores need a sink |
| HistoryStore (IssueLog) | optional | without it, agent bootstrap replay is empty (today's behaviour for non-joinable events) |
| TrustClassifier (GHD) | optional | default: treat as untrusted |
| Signal port (#11, MP-R1) | consumer | Alerts publish through it to the bus |
| Phoenix PubSub | **not** a dependency of `aiur_events` core | only `DebugLog` uses it; it moves behind an optional debug sink |
| `aiur_web` | never depended on by the bus | the web adapter depends on the bus |

Config ownership: `events.*` (`config/schema/events.ex`) registers with the
bus; `codeowners_refresh_seconds` moves to the trust-classifier owner; new
`events.export.{enabled,retention}` (DESIGN-R2 S1). Every key ships with its
docs row in `website/docs-app/reference/configuration.md` (AGENTS.md "Docs
ship with the change"; `scripts/check-config-docs.py` enforces it).

### 4.4 Bucket classification (settled by RC-09; original text kept)

C1–C4 are behaviour-preserving (Bucket 1). C5 (catalog/envelope), C6 (export
journal, durable consumer) and C7 (external API) add capability with no
user-facing change when disabled. **Recommendation:** keep them under MP-R2
because they are the contract's implementation and must land once, but tag
them `Bucket-2-enabling`, ship them disabled by default, and schedule each
just before its first consumer: C5 before MP-E2/MP-E4; C6 before MP-E1 only if
E1 chooses the durable consumer (it need not, §8), otherwise before MP-N4;
C7 before MP-N3.

## 5. Alternatives considered

| Option | Verdict | Reason |
| --- | --- | --- |
| A. Merge PubSub into the Exchange (one bus) | Rejected | 50 PubSub shapes are invalidations and streams with no need for ids or patterns; routing them through the Publisher gates (tracked-set filter, dedup) would change behaviour and add load. F6. |
| B. Keep both buses, no rule (status quo) | Rejected | Leaves MP-Q5 open; new features would place facts by convenience and leak PubSub messages to clients. |
| **C. Two buses with a placement rule, Exchange as the only export path, snapshot + cursor feed** | **Recommended** | Matches the documented "events are signals" rule (`message-bus.md:14`), the Stream Deck reconnect pattern (F7), and the Executor journal precedent (F5); needs no broker. |
| D. External broker (NATS, Redis Streams, MQTT) | Rejected | No evidence of need: one instance, one daemon, single node (`id_generator.ex:52-56`); adds a mandatory runtime dependency the brief forbids. |
| E. Make replay durable by widening IssueLog to all ticket events | Rejected for this feature | Behaviour change (Bucket 2), per-ticket only, no `system.*` scope, and it changes what agents receive on bootstrap. MP-E4 may propose it separately. |
| F. External feed without replay (snapshot + live only) | Kept as the degradation path | It is what a client does after `reset`; on its own it cannot support push producers that must not miss a blocker (MP-N4). |
| Transport: SSE vs long-poll vs Phoenix channel | Pull (HTTP) + Phoenix channel | Pull is resumable and works from a mobile background task; the channel reuses the Stream Deck token/socket pattern for foreground clients. SSE adds a third mechanism with no reuse. |

## 6. Contracts

**Owned:** [contracts/events-and-replay.md](../../contracts/events-and-replay.md)
(event identity, envelope, ordering, durability classes, replay/reconciliation,
versioning, topic catalog, external subscriber API).

**Consumed — assumptions the coordinator must reconcile:**

| Contract | Owner | Assumption MP-R2 needs |
| --- | --- | --- |
| Identity (machine, instance, repository) | not assigned (MP-R1 or MP-N2) | Stable opaque `instance` and `machine` ids, never reassigned; else the export journal uses `epoch` resets (contract §3) |
| Capabilities | MP-R1 | A capability record can advertise `events.export {v, retention}` and absence means unavailable |
| Pairing credentials | MP-N2 | A read-only scope exists that the feed accepts; tailnet reachability is never authorization |
| Command request and resolution | MP-E2 | DecisionStore remains truth; lifecycle stays on `ticket.<id>.agent.decision.<slug>` + `executor.decision.*`; `decision_id` + `version` suffice for clients to re-fetch |
| Conversations and anchors | MP-E4 | E4 computes `anchor`; the bus reserves the field and never derives it |
| Build progress and queue readiness | MP-E1 | Queue publishes under `ticket.<id>.queue.*` / `system.queue.*`; build-order progress producer publishes `system.build_order.<root>.progress` |
| Notification destination/payload | MP-N4 | Push producer consumes the export feed through the durable consumer and fetches text from authenticated APIs |
| Signal port | MP-R1 (prior #11) | Alerts reach the bus through one call; classes/allowlists apply at the bus |

## 7. Non-happy paths

| Case | Behaviour required |
| --- | --- |
| Capability absent (export disabled, package not installed) | `GET /api/v1/events` → 404 `feature_disabled`; capability absent; no client shows zeros (MP-N3 shows "unavailable"). |
| Stale data | Feed responses carry `head_seq`; live channel heartbeats every 25 s; clients mark stale by time since last heartbeat, never by event silence. |
| Daemon restart | `IdGenerator` continues without reuse; exporter writes a `gap(scope:"*")` covering downtime; in-BEAM consumers keep today's recovery (§7.1 of contract). |
| Exporter crash mid-append | Corrupt tail detection → `events_unavailable` + one `needs_attention` alert; no silent truncation of retained lines. |
| Duplicates | Publisher dedup unchanged; feed clients dedupe on `(instance, id)`; `renotify` deliberately produces a new id with the same `decision_id` (`executor_events.ex:28-55`) and clients must treat it as a re-alert, not a duplicate. |
| Out-of-order ids | Contract O-1/O-2; feed order is `seq`; witness test documents in-BEAM risk (F2). |
| Multiple devices | Each device keeps its own `seq` cursor; the feed has no per-device server state; read-only, so no conflicts arise on the bus (conflicting *answers* are MP-E2's). |
| Cursor older than retention / new epoch | One `reset` record; client re-snapshots; push producer suppresses backlog notifications (MP-N5 rule). |
| Privacy | Export allowlist per topic, identifiers and enums only; no comment bodies, titles, failure excerpts; feed behind dashboard auth/paired-device auth; never on the webhook pipeline; loopback default bind (MP-R3). |
| Security: untrusted GitHub text | Unchanged: `scrub_untrusted_output` for Executor output (`executor_events.ex:195-217`); the feed never carries the text in the first place. |
| Back-pressure | Exchange stays fire-and-forget; the exporter is a single subscriber with a bounded mailbox alarm (log + alert when message queue length exceeds a threshold); RQ-4 sizes it. |

## 8. What each consumer needs from the bus

| Feature | Needs (exists = ✓, gap = ✗) | Delivered by |
| --- | --- | --- |
| **MP-E2 Commands** | Lifecycle events with `decision_id`, `version` ✓ (journaled via DecisionStore); Executor stream `executor.decision.requested|deferred` ✓; resolution events to clear notifications ✓ (`answered`, `expired`, `mooted`, `resolved` slugs); export of ids for phone/watch ✗ | C5 catalog entries; C6/C7 for remote |
| **MP-E1 queue readiness** | `ticket.*.pr.merged` ✓ (live); PR closed unmerged ✗; issue closed/reopened ✗; dependency-edge change ✗ (F8); dispatch capacity `system.dispatch.*` ✓; a place to publish readiness/hold/unpromote ✗ | E1 reconciles from tracker + graph (events are triggers only); R2 reserves `ticket.<id>.queue.*`/`system.queue.*` (C5); optional durable consumer (C6) |
| **MP-E1/MP-N5 progress** | Agent progress `ticket.<id>.agent.progress*` ✓ (logged); build-order % ✗ (PubSub only, F9); PR merges ✓ (live); threshold state ✗ | Build-order producer of `system.build_order.<root>.progress` (owned by build orders, scheduled with N5); N5 computes thresholds in one daemon-side consumer (C6 durable consumer) |
| **MP-E4 event→conversation** | Stable `id` ✓; `occurred_at`/`observed_at` ✓ (TicketObservation); ticket identity ✓ for joinable, topic-only otherwise; durable per-ticket history of non-agent events ✗ (F1); anchor ✗ | Envelope `anchor` field reserved (C5); export journal queryable by `refs.ticket` (C6) as the durable index, or E4's own widening (alt E) |
| **MP-N4 push** | Durable cursor that survives daemon restart ✗; gap/reset signalling ✗; dedupe key ✓ (`id`) | C3 + C6 durable consumer on the export journal |
| **MP-N3 meta-dashboard** | Freshness probe ✗; counts from snapshots ✓ (`/api/v1/state`) | C7 `head_seq` + heartbeat |
| **MP-N6 response** | `instance` + `decision_id` in the record ✗ (instance implicit) | C5 envelope |
| **MP-E3 Executor chat** | `executor.*` journal ✓; chat is not a bus fact | none beyond C1–C4 |
| **MP-E7 listener modes** | delivery to a running agent — today `SubscriptionStore → Orchestrator` digest ✓ | `Aiur.Events.Delivery` behaviour (C2) is the seam E7 plugs into |
| **MP-R6 Stream Deck** | unchanged (PubSub + projections) | none |

## 9. Open questions

### Owner (Kevin) — in DESIGN-R2

- KQ-R2-1 export retention default; KQ-R2-2 ship `aiur events tail`?;
  KQ-R2-3 identifiers-only external feed (recommended).

### Coordinator

- MP-KD-R2-1 classification and scheduling of C5–C7 (§4.4).
- Assign the Identity contract owner (contract §3 assumption).
- Confirm MP-R1 decides physical package layout (in-repo Mix project vs
  directory boundary) before C4.

### Research (Phase C resolves with evidence)

| ID | Question | How to settle |
| --- | --- | --- |
| RQ-1 | Does an unattributed `ticket.N.pr.merged`/`ci.failed` publish ever write an IssueLog line (F1)? Does the Stream Deck log show CI/PR keys only via agent emits? | Witness test C1-T01 with a registered writer; read `StreamdeckLogs` fixtures |
| RQ-2 | Can two publishers deliver ids out of order to one SubscriptionStore/ExecutorListener and lose the lower id (F2)? | Witness C1-T02 with injected id/publish interleaving; production-hunk rule applies to any fix (U3) |
| RQ-3 | Which existing journal primitive becomes `Aiur.Events.Journal` without duplicating `DecisionLog` (MP-R1 kernel ownership)? | Read `decision_log.ex` callers; agree with MP-R1 |
| RQ-4 | Export rate and mailbox bound: events/hour by topic on a live instance | Count a day of `aiur:events:debug` or publisher DebugLog output on the dogfood host (census with date and size, AGENTS.md "measured" rule) |
| RQ-5 | Producers of `system.dispatch.*`, `system.fleet.*`, `system.tracker.*`, `system.config.base_branch.changed` | `git grep` for each topic literal and helper at the implementation SHA |
| RQ-6 | Is `Webhooks.EventSource` dead? | xref callers; if dead, delete in C2; else route through Publisher |
| RQ-7 | Router ordering for `/api/v1/events` against `/api/v1/:issue_identifier` | Router test in C7-T01 |
| RQ-8 | Physical-package mechanics: Mix in-umbrella app vs `path:` dep, compile-time `persistent_term`/Registry names | MP-R1 packaging spike |

## 10. Acceptance criteria (feature level)

1. `mix xref graph --label compile-connected` from the `aiur_events`
   boundary shows no dependency on `Aiur.Orchestrator*`, `AiurWeb*`,
   `Aiur.GitHub.CodeOwners`, or `Aiur.IssueLog` (only behaviours).
2. All existing event tests pass unchanged in name and assertion:
   `test/aiur/events/*`, `executor_*_test.exs`, `orchestrator/auto_subscriptions_test.exs`,
   `universal_subscriptions_test.exs`, Stream Deck channel/logs tests.
3. C1 characterization tests pass before and after every C2–C4 move, in a
   clean worktree, with the commands recorded in each PR body.
4. Supervision order test: `IdGenerator`, `Exchange`, `Publisher` precede every
   subscriber; killing `Exchange` re-binds `ExecutorListener`, `TicketActivity`,
   `Orchestrator.Lifecycle` and running `SubscriptionStore`s within one
   resubscribe interval.
5. Contract §2 placement table is enforced by a test: every Exchange topic
   prefix is one of `ticket.`, `system.`, `executor.`; no module outside the
   allowed bridge list both subscribes to the Exchange and broadcasts PubSub.
6. With `events.export.enabled: false` (default) no new file, route, socket or
   process exists and `aiur status` output is byte-identical.
7. With export enabled (C6–C7): resume-after-disconnect returns exactly the
   records after `seq`; a cursor older than retention returns one `reset`;
   restart produces one `gap`; no record contains a non-allowlisted key
   (property test over the catalog).
8. Docs: `website/docs-app/concepts/message-bus.md` gains the placement rule
   and durability classes (C4); `reference/configuration.md` and
   `reference/cli.md` rows for every new key/command (C6–C7).

## 12. Phase C changes (2026-10-06)

Ticket research changed this plan as follows. Tickets are authoritative.

| Item | Change | Evidence / decision |
| --- | --- | --- |
| RQ-1 | Settled statically; C1-T01 is the witness | `publisher.ex:337-357`, `issue_log.ex:545-560,573-581` |
| RQ-2 | Deterministic interleaving witness (C1-T02); finding goes to U3 | contract O-4 |
| RQ-3 | `DecisionLog` is a generic kernel primitive (16 callers, depends only on `Aiur.Fs`); MP-R1-C5-T1 moves it; `Aiur.Events.Journal` is a thin facade (C3-T01) | `git grep DecisionLog.` at base |
| RQ-5 | All `system.dispatch/fleet/tracker/config.*` producers go through `Aiur.Alerts.emit_system` → `ledgered` | contract §6 |
| RQ-6 | `Webhooks.EventSource` has no production caller; default routed through the Publisher (C2-T04), not deleted (U7 decides cuts) | `webhook_mode_contract.exs:85,100-108` |
| RQ-7 | New routes go before `router.ex:191`; otherwise `/api/v1/:issue_identifier` (`:193`) shadows them | C7-T01 |
| RQ-8 | Logical component in `components.json` (MP-R1-KD1/KD7); no Mix app, no file moves, no renames | C4-T01 |
| §4.1 members | `Sanitizer`, `BranchRefStore`, `CommentFilter`, `EventPublicationLog`, `DebugLog` are not bus-core members; manifest-only reassignment (C2-T11, CR-R2-1) | caller census |
| New seams | Publisher's GitHub gates → `SourcePolicy` (C2-T06, gate order kept); IdGenerator cold-boot floors injected from boot (C2-T07); SubscriptionStore dead-letter alert → `Delivery.dead_letter/5` (C2-T01) | `publisher.ex:188-246`, `id_generator.ex:294-336`, `subscription_store.ex:500-514` |
| HistoryStore | Write sink only (C2-T03); readers keep `IssueLog.event_history/2` | readers are not bus members |
| TrustClassifier | Consumes U5's single KTD9 trust snapshot; defines no trust rules (RC-21) | C2-T02 |
| C4-T02 | Absorbed by MP-R1-C4 (events section registration) | MP-R1 plan C4 |
| Exporter placement | End of the always-on block, not after the Exchange (avoids a `:rest_for_one` cascade); boot `gap` covers the late bind | contract §8 |
| Anchors | RC-07: envelope `anchor` reserved, `null` in v1 | contract §4.2 |
| Topic catalog | RC-08 registrations incl. `system.capabilities.changed`; seven legacy alert-name topics classified `ledgered` | contract §9, C1-T05 |
| AC1 | Boundary gate is MP-R1's `scripts/check-components.py` (C4-T03), with `bus_boundary_test.exs` (C1-T06) as the interim ratchet; there is no `mix xref` gate in the repo | `.github/workflows/ci.yml` lint job |
| Size owner | Looked up at ticket start (RC-23) | |

## 11. Plan refresh (after MP-R1..R7 land)

| Item | Before (45a290e3) | After refactor | Refresh task |
| --- | --- | --- | --- |
| Paths | `src/lib/aiur/events/*`, `executor_events.ex` | `aiur_events` package path chosen by MP-R1 | MP-R2-C4-T04 rewrites every MP-R2 ticket's file list and every consumer contract citation |
| Sink | `GenServer.call(Aiur.Orchestrator, {:enqueue_event_digest,…})` | `Aiur.Events.Delivery` impl in ORC (and later MP-E7 listener modes) | MP-E7 plan cites the behaviour, not the orchestrator call |
| Alerts | direct `Aiur.Alerts` → Publisher | signal port (#11) → bus | contract §6 `ledgered` row re-cited |
| Journal | `DecisionLog` | kernel journal (MP-R1) | C3 tickets re-cite |
| Harness events | runner-owned | MP-R7 adapters publish agent events through `Aiur.Events.publish` | MP-R7 plan must keep the `tool_executor` joinable identity (F1) |

Chunk decomposition, tickets and per-chunk test strategy: [chunks.md](chunks.md).
