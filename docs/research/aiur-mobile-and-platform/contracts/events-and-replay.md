---
contract_id: MP-CT-events-and-replay
owner_feature: MP-R2
status: reconciled (Phase D fix pass; applies RC-02, RC-04, RC-07, RC-08, RC-09, RC-31, RC-40; X-07, X-08, X-09, security m3; implementation blocked on DESIGN-R2)
base_main_sha: 45a290e3
date: 2026-10-06
consumers: MP-E1, MP-E2, MP-E3, MP-E4, MP-E7, MP-N3, MP-N4, MP-N5, MP-N6, MP-R1, MP-R6
tickets: ../bucket-1-refactor/MP-R2/tickets/README.md
evidence: ../bucket-1-refactor/MP-R2/plan.md, ../bucket-1-refactor/MP-R2/inventory.md
---

# Contract: events, identity, ordering, replay and the external feed

This contract defines what aiur's event bus promises and, just as important,
what it does not promise. Every claim about *today* is pinned to
`45a290e3` and cited in [inventory.md](../bucket-1-refactor/MP-R2/inventory.md).
Everything marked **proposed** is new and blocked on DESIGN-R2.

## 1. The rule this contract rests on

> "Events are signals; consumers follow validated references or correlation
> fields to the durable source of truth."
> — `website/docs-app/concepts/message-bus.md:14` (already documented product rule)

Consequences, binding on every consumer:

1. **The bus is not a database.** A consumer that must be correct after a
   restart, a disconnect or a missed message reconciles against the owning
   store (DecisionStore, tracker/ResourceStore, build-order graph, queue
   store), using the event only as a trigger and a correlation key.
2. **No new mandatory broker.** The bus stays in-BEAM (`Aiur.Events.Exchange`).
   No NATS, Redis, Kafka or cloud service is required. The only new durable
   artifact proposed is a bounded local file (the export journal, §8).
3. **Free text does not leave the daemon on the bus.** External events are
   identifiers and enumerations; text is fetched from the authenticated source
   API (precedent: `ExecutorWakeProjection` records are identifier-only).

## 2. Which channel owns which fact (resolves MP-Q5)

Aiur has two in-process buses and several durable stores. They are not
competitors; each carries a different kind of fact. A new fact is placed by
this table, not by convenience.

| Fact kind | Channel that carries it | Durable truth | May leave the daemon? |
| --- | --- | --- | --- |
| **Coordination event**: something happened to a ticket, the integration branch, the fleet or the Executor (`ticket.*`, `system.*`, `executor.*`) | **Exchange** (`Aiur.Events.Publisher` → `Exchange`), pattern-routed, carries an `IdGenerator` id | Depends on class (§6): tracker, IssueLog, journal, alert ledger | Yes, through the export feed only, allowlisted per topic |
| **Command lifecycle** (requested, answered, delivered, acknowledged, resolved, expired, mooted, deferred) | DecisionStore writes first, then Exchange (`ticket.<id>.agent.decision.<slug>`, `executor.decision.*`) and PubSub `decisions:changed` | DecisionStore journal | Ids and versions only; content via the Decision API |
| **Projection changed** ("re-read X"): dashboard, current run, ticket activity, build-order graph/detail/history, usage, meters, financial, open tickets, webhook mode, workflow config | **Phoenix PubSub `Aiur.PubSub`**, literal topics, no event id, best effort | The owning store/projection | **Never.** External clients re-read the snapshot API |
| **Live transcript stream** (`agent:<id>` transcript, alert, turn, lifecycle messages) | PubSub `agent:<id>` | IssueLog transcript file (`IssueLog` subscribes to `agent:<id>`) | Through the conversation API (MP-E4 contract), never the bus |
| **Runtime and UI plumbing** (opencode slots, attach pool, pane status, perf, prewarm phase, debug mirror, Claude hook relay) | PubSub | None | Never |
| **Executor wakes** (identifier-only digest of allowlisted events for `executor-wait`) | A *consumer* of the Exchange (`ExecutorListener` → `ExecutorWakeInbox`) | `executor.wakes.ndjson` + cursor | No; private to the Executor principal |
| **Client transport** (Stream Deck `streamdeck:fleet`, `/voice`, LiveView) | Phoenix Channels / LiveView sockets, fed by PubSub + projections | n/a | They are clients, not buses |
| **Instance existence** | Launcher instance records (`$AIUR_BG_STATE_DIR/instances/*.instance`, default `~/.config/aiur/instances`) | Those files | Discovery (MP-N2), not the bus |

Placement rules for new facts:

- **R-1.** If any consumer needs identity, pattern routing, ordering,
  replay, cross-ticket delivery or delivery outside the daemon, the fact is an
  Exchange event.
- **R-2.** If the message only means "something you render changed, re-read
  it", it is a PubSub notification and must carry a generation/version, never
  the data a consumer will treat as truth.
- **R-3.** A producer that writes a durable store *and* notifies follows the
  DecisionStore order: persist, then publish to the Exchange with the durable
  id, then broadcast PubSub (`decision_store.ex:2558,2572`).
- **R-4.** Bridges run one way, Exchange → PubSub (existing:
  `TicketActivity`, `TicketHistoryProvider`, `DecisionMetrics`). There is no
  PubSub → Exchange bridge and none may be added; a fact that needs the
  Exchange is published there by its producer.
- **R-5.** The bus package owns the Exchange, the publish boundary, ids,
  cursors, durable-consumer primitives and the export feed. It does **not**
  own the PubSub topics; each PubSub topic stays with the feature that owns
  the projection (prior boundary map: `AgentPubSub` → RUN, `DecisionPubSub`
  → DEC, `ObservabilityPubSub` → WEB/PRJ). The `Aiur.PubSub` process itself
  is app-boot infrastructure (kernel layer, MP-R1).
- **R-6 (Phase D, CR-C8-2).** `Aiur.ObservabilityPubSub` is an
  internal-invalidation PubSub topic: never exported, never bridged to the
  Exchange. Its move out of the web namespace is owned by MP-R1-C5-T03 (RC-24),
  which places it in the signal component, not in `event-bus` (R-5). Live bug
  #3009 (`CurrentRunProjections` ignores the broadcast) is fixed before that move
  or explicitly deferred in its PR.

## 3. Event identity

| Field | Today | Contract |
| --- | --- | --- |
| `id` (event id) | One integer per instance from `Aiur.Events.IdGenerator`: monotonic in *assignment*, restart-safe (`event-id.json` in the instance- and repository-qualified runtime state dir), gaps allowed, roughly microsecond-sized (`id_generator.ex:1-56`) | Unique within one instance, never reused. **Not dense, not a delivery order** (§5). |
| `instance` | Implicit (one daemon = one repository) | **Proposed:** every exported event carries `instance` = `instance_id` = `"<machine_id>/<instance_key>"` from the Identity contract (RC-02; owner MP-R1, RC-04; provider MP-R1-C2-T02, adapter MP-R2-C5-T04). Globally an event is `(instance, id)`; `machine` is the prefix of `instance`. |
| `seq` (feed position) | Does not exist | **Proposed:** dense, single-writer position in the export journal (§8). It is the only cursor external clients use. |
| Correlation keys | Topic-embedded ticket id; payload `decision_id`, `pr_number`, `head_sha`, `wake_id` | Exported as typed `refs` (§4). |

Assumption on the Identity contract (owner MP-R1, RC-04): `instance_id` is
an opaque string, stable across daemon restarts and upgrades. The identity
contract says a moved checkout gets a new `instance_key` and therefore a new
`instance_id` (identity-and-capabilities §1.2); clients treat that as a new
instance. An instance with an empty key has no `instance_id`
(`identity: degraded`); the exporter then refuses to start and the
`events.export` capability is `unavailable` with reason `dependency_unavailable`,
`depends_on: ["identity"]` (identity §2.2; Phase D, CR-R2-4). Because the
exporter refuses, an exported envelope never has a null `instance`; the internal
envelope (§4.1) carries no `instance` field, so no null is needed there either
(CR-R1-1). A corrupt export-journal tail reports the reason `journal_corrupt`
(state per MP-R2-C7-T03).
The export journal still embeds a per-journal `epoch`, and clients treat a
new epoch as `reset` (§7).

## 4. Envelopes

### 4.1 Internal envelope (today, unchanged by this feature)

A plain map delivered as `{:event, map}`: the producer payload (mixed atom and
string keys) plus atom `id` and `topic`, optional `digest_source`, and an
always-present `ticket_observation` (`publisher.ex:298-304`).
`Aiur.TicketObservation` v1 fields: `version`, `status`
(`:joinable | :unattributed`), `reason`, `tracker_identity`, `source`,
`event_id`, `provenance`, `occurred_at`, `observed_at`, `payload_version`,
`attributes` (`ticket_observation.ex:36-62`). Replayed `executor.*` events are
JSON-normalized with string keys. MP-R2 packaging (C1–C4) does **not** change
this shape.

### 4.2 External envelope v1 (proposed)

```json
{
  "v": 1,
  "instance": "<instance id>",
  "seq": 18234,
  "id": 1791281110183123,
  "topic": "ticket.142.pr.merged",
  "class": "live",
  "occurred_at": "2026-10-06T15:02:11Z",
  "observed_at": "2026-10-06T15:02:13Z",
  "source": "legacy",
  "refs": {"ticket": "142", "pr_number": 2210, "head_sha": "abc1234",
           "decision_id": null, "decision_version": null},
  "attrs": {"action": "merged"},
  "payload_version": 1,
  "anchor": null
}
```

- `refs` and `attrs` come from a **per-topic allowlist** in the topic catalog
  (§9). Unknown or unlisted payload keys are dropped, never passed through.
- `attrs` values are enums, numbers, booleans or ids. No comment bodies, titles,
  messages, failure excerpts or file paths (DESIGN-R2 KQ-R2-3).
- `source` is derived from the observation source kind, which today is only
  `agent_event`, `agent_alert` or `legacy` (`ticket_observation.ex:55`); it
  never claims `github` until producers supply that kind (MP-R2-C5-T02).
- `occurred_at` may be `null` (unknown); it is never replaced by the current
  time (rule already in `ticket_observation.ex:64-71`).
- `anchor` is reserved for MP-E4 (RC-07). The address of a conversation
  position is the **E4 durable journal position**:
  `{"conversation_id": "conv_…", "pos": 1207, "placement": "at|after",
  "precision": "exact|causal|observed|unanchored"}`
  (conversations-transcripts-anchors §10; Phase D, CR-E4-1). `anchor_id` is not
  part of the field: it is E4's line identity, read through E4's anchor API.
  The stable entry ID is the `pos`
  the journal writer assigns. The bus never computes an anchor, and the
  export journal is append-only, so **v1 always writes `anchor: null`**;
  clients resolve anchors through E4's anchor API by `(instance, id)`. A
  producer may set the field only when it already knows the position at
  publish time; that is a later, separately approved change.

### 4.3 Control records on the feed

| `type` | Meaning | Client action |
| --- | --- | --- |
| `event` (default) | One envelope as above | Apply, dedupe on `(instance, id)` |
| `reset` | Requested cursor is older than retention, or the journal epoch changed | Drop local event-derived state, re-read snapshots, resume from `oldest_seq`/`head_seq` given |
| `gap` | The exporter itself missed events (it was down, or a publish happened while it was not subscribed) between two `seq`s | Re-read snapshots for the affected `scope` (ticket or `*`) |
| `heartbeat` | Live channel liveness, carries `head_seq` | Update freshness; no state change |

## 5. Ordering

What holds today (verified):

1. **Per publishing process, FIFO.** `Exchange.publish/3` runs `send/2` in the
   caller's process (`exchange.ex:93-108`); Erlang preserves order between one
   sender and one receiver.
2. **Nothing else.** The id is taken from a GenServer call
   (`id_generator.ex:83-85`, `publisher.ex:221`) and delivery happens later in
   the caller. Two publishers can therefore deliver id 11 before id 10. Durable
   publishers widen the window: `ExecutorEvents.publish` reserves the id, then
   appends and syncs the journal, then publishes (`executor_events.ex:64-75`).
3. Consumers that keep a max-id cursor and drop `id <= cursor`
   (`SubscriptionStore` `subscription_store.ex:397-400`; `ExecutorListener`
   for `executor.*`, `executor_listener.ex:169-178`) can therefore drop an
   out-of-order lower id. This is a **source-reachable hypothesis**, not a
   measured incident (MP-R2 RQ-2, witness ticket MP-R2-C1-T02).
4. Known in-store reorder: `resolve_stall/2` re-sends buffered events to its
   own mailbox behind any newer queued event (`subscription_store.ex:484-492`);
   prior finding `events-webhooks-executor-01`, owned by prior unit U3.

Contract:

- **O-1 (internal, unchanged).** In-BEAM subscribers get per-publisher FIFO
  only. They must not infer global order from `id`.
- **O-2 (external, proposed).** The export feed is totally ordered by `seq`,
  assigned by one writer in receive order. `seq` order is *observed* order,
  not causal order and not `id` order.
- **O-3.** Per ticket, a client that needs "latest state" (PR merged? Command
  resolved?) reads the owning snapshot; it does not fold events to derive it.
- **O-4.** A fix for item 3 (for example a per-consumer reorder window, or
  publishing through a single sequencer) is behaviour-changing and belongs to
  U3 or a Bucket 2 ticket, not to the MP-R2 packaging chunks.

## 6. Durability classes

Every topic in the catalog (§9) declares one class. Today's classes are a
description of current behaviour, not a promise to keep its gaps.

| Class | Meaning | Today's members (verified) |
| --- | --- | --- |
| `ephemeral` | Lost on crash or if nobody listens; consumer re-reads its source | Every PubSub topic; `aiur:events:debug*` mirror |
| `live` | Has an event id, delivered only to subscribers bound at publish time; no durable copy | `system.<branch>.branch.push`; unattributed `ticket.*` events from GitHub/CI/orchestrator (IssueLog drops them: `issue_log.ex:573-581`); `system.*` without an alert |
| `ledgered` | Delivered live; a separate audit record exists (alert ledger), not replayable by cursor | `system.*` and `ticket.*.agent.attention.*` emitted through `Aiur.Alerts` (`alerts.ex:191-197,245`); every `system.dispatch.*`, `system.fleet.*`, `system.tracker.*` and `system.config.base_branch.changed` producer (Phase C RQ-5: `orchestrator/issue_sync.ex:580,600,1787,2052,2285,2294`, `orchestrator/dispatcher.ex:671,698,764,789,2010-2016`, `workflow_store.ex:37,512`); and seven legacy alert topics outside the topic grammar that `Aiur.Alerts` publishes under the alert name, e.g. `decision_store.corrupted`, `executor_events.corrupted` (`alerts.ex:144-152,293-313`; list in MP-R2-C1-T05) |
| `logged` | Async, best-effort per-ticket marker in the IssueLog event log, readable with `since_id` | Agent-emitted `ticket.<id>.agent.*` with a joinable identity (`tool_executor.ex:123,441`), only while that ticket's writer is registered (`issue_log.ex:545-560,616`) |
| `journaled` | Appended (and synced) **before** fan-out; replayable by cursor | `executor.*` (`executor_events.ex:448-452`); Command lifecycle via DecisionStore (`decision_store.ex:2558,4608`); Executor wake records (`executor_wake_inbox.ex`); webhook deliveries (`Aiur.Webhooks.DeliveryLog`) |
| `exported` (**proposed**) | Copied into the bounded export journal by the exporter; replayable by `seq` until retention | Every catalog topic marked `export: true` |

Rules:

- **D-1.** A consumer may rely on replay only for `journaled` and `exported`
  topics, and only within retention. For every other class, restart recovery
  is reconciliation against the owning store.
- **D-2.** `exported` does not upgrade the producer's guarantee: an event
  published while the exporter was not subscribed is lost to the feed and
  surfaces as a `gap` record, never silently.
- **D-3.** Retention is bounded by `events.export.retention` (DESIGN-R2 S1).
  Retention never deletes a transcript or a Command record; it only trims the
  export copy.
- **D-4 (Phase D, CR-E7-6).** Pending operator messages are not durable at base:
  `AgentQueueStore` is in-memory (`agent_queue_store.ex:2-3`; `durability:
  :durable` persists nothing). No contract may promise that a queued message
  survives a daemon restart; after a restart its receipt is `unknown`
  (listener-mode §7). MP-E3, MP-E4 and MP-N6 render it that way.

## 7. Replay, reconnection and reconciliation

### 7.1 In-BEAM consumers

Existing patterns, preserved as-is by packaging:

| Consumer | Cursor | Replay source | Gap behaviour today |
| --- | --- | --- | --- |
| `SubscriptionStore` (per running ticket) | `last_seen_event_id` per ticket file; per-binding `subscription_created_at_event_id` floor | `BootstrapDigest` reads `IssueLog.event_history(since_id:)` for concrete `ticket.<id>` patterns on the agent's first turn | `system.*` and wildcard patterns are not replayed (`bootstrap_digest.ex:78-80,110-126`); `live`-class ticket events published while the agent was down are not replayed |
| `ExecutorListener` | `executor.listener.watermark.json` for `executor.*` only | Executor journal | Non-`executor.*` wakes published while the listener was unbound are lost (watermark advances only for `executor.*`, `executor_listener.ex:149-153`) |
| `executor-listen` CLI | `executor.subscriptions.json` `last_seen_event_id` | Executor journal, then live | Same as above |
| Orchestrator, TicketActivity, TicketHistoryProvider, DecisionMetrics, RunTelemetry.Writer | None | None | Recover by their own reconciliation (poll, snapshot, history read) |

**Proposed durable-consumer primitive** (C3): a named consumer with a persisted
cursor over the export journal, offering `replay(after) → events | reset`,
used by new daemon-side consumers (push producer MP-N4, notification rules
MP-N5, optionally queue MP-E1). It is the ExecutorListener pattern
(subscribe first, then replay from cursor, then live, dedupe on id)
generalized to `seq`.

### 7.2 External clients

1. **Bootstrap**: read snapshots (state API, Decision API, conversation API),
   note the feed `head_seq` *before* the snapshot read.
2. **Follow**: `GET /api/v1/events?after=<head_seq>` or join the live channel
   with `after`.
3. **Apply**: dedupe on `(instance, id)`; treat each event as "refresh the
   object named in `refs`".
4. **Reconnect**: resume with the last applied `seq`. On `reset`, go to 1. On
   `gap`, re-read snapshots for the gap's scope.
5. **Stale**: clients compute freshness from the last `heartbeat`/response
   time and `observed_at`; they display stale distinctly from idle (brief
   §7, MP-N3).
6. **No burst after reconnect**: a client or push producer must not turn a
   replayed backlog into user notifications without a staleness rule. That
   rule is owned by MP-N5; the feed supplies `observed_at` and `seq`.

## 8. Export journal (proposed; C6)

- One writer process (the exporter) subscribes to the Exchange with the
  catalog's exported patterns. **Placement (changed in Phase C):** it starts
  as the last child of the `:rest_for_one` tree, after `cli_children`
  (`aiur.ex:118,482-484`), not right after the Exchange. A mid-tree exporter crash would otherwise restart the
  Publisher, DecisionStore and Orchestrator. Events published before it
  binds are covered by the boot `gap` record below, so binding late loses
  nothing silently. An Exchange crash still restarts the exporter (it is
  later in the tree), which re-binds and writes a new `gap`.
- The export journal is registered as an `IdGenerator` cold-boot floor file
  (MP-R2-C2-T07 `:floor_files`), because it can hold ids higher than any
  per-issue log.
- File: `<runtime_state_dir>/events/export.ndjson` + `export.meta.json`
  (`epoch`, `oldest_seq`, `head_seq`). Append uses the existing
  `DecisionLog.prepare/append` journal primitive; a corrupt tail stops the
  feed with `events_unavailable` and one `needs_attention` alert (precedent:
  `executor_events.ex:416-440`).
- On boot (and on every restart) the exporter writes a `gap` record
  covering the downtime (`scope: "*"`) **after** it has subscribed, because
  it cannot know what was published while it was down or unbound.
- Trimming keeps `seq` dense and moves `oldest_seq`; it never rewrites
  retained lines.
- Disabled by default (`events.export.enabled: false`) until its first
  consumer ships; while disabled the API returns `404 feature_disabled` and
  the capability (§10) is reported as `unavailable` with reason `disabled`
  (never left out: identity §3 reads a missing ID as `unknown`).

## 9. Topic catalog and versioning

- **Topic grammar is frozen** for the life of this contract:
  `ticket.<id>.<surface>.<verb>[.<qualifier>]`, `system.<area>.…`,
  `system.<base_branch>.branch.push`, `executor.…`
  (`message-bus.md:5-12`, `.claude/skills/aiur-agent/event-taxonomy.md`).
  Agents, the Executor skill and `ExecutorBindings` depend on these strings;
  a rename is a breaking change requiring a separately approved ticket.
- **Catalog** (proposed, C5): a code-level registry `topic pattern → {class,
  export?, refs allowlist, attrs allowlist, payload_version, owner feature,
  attribution?}`.
  Unknown topics are `live`, not exported. A test fails if an exported topic
  lacks an allowlist.
- **Registered topics for planned producers (RC-08).** The catalog
  (MP-R2-C5-T03) registers all of these; the bus does not produce them:

  | Topic | Producer (owner) | Class |
  | --- | --- | --- |
  | `ticket.<id>.agent.decision.human-needed` and `executor.decision.human-needed` | DecisionStore (MP-E2) | journaled, exported; refs `{decision_id, decision_version}`, attrs `{requester_kind, blocking, urgency, cause}`. **`short_label` is not exported** (security m3): it is agent-authored text, which §1 and §4.2 keep out of the feed. It travels only inside the sealed push (notification contract), and clients read it from the Decision API |
  | `ticket.<id>.agent.decision.{request-attributed, routed, escalated, executor-acknowledged, native-released, requester-notified}` (and `executor.decision.*` twins) | DecisionStore (MP-E2) | journaled |
  | `executor.decision.answered` | DecisionStore (MP-E2-C6-T02) | journaled; export optional, ids only |
  | `ticket.<id>.pr.closed_unmerged` | **MP-E1-C4-T05**, from the stored webhook delivery it already reads (RC-26); webhook mode only | live |
  | `ticket.<id>.issue.closed` | reserved; no producer in v1 (the queue reads `issue_closure/1` and does not need it, CR-E1-2) | live |
  | `ticket.<id>.agent.listen-mode.changed` | listener modes (MP-E7) | live; **attribution from payload `actor`** (below) |
  | `ticket.<id>.queue.{promoted,withdrawn,held,released,overridden,removed}` | build queue (MP-E1) | live |
  | `ticket.<id>.queue.attention.<cause>` (+ `.resolved`) | build queue (MP-E1) | ledgered |
  | `system.queue.<queue_id>.progress` (milestones; the topic has **no** `.milestone` suffix, X-09) | build queue (MP-E1-C7) | ledgered |
  | `system.queue.attention.<cause>` (+ `.resolved`) | build queue (MP-E1) | ledgered |
  | `system.build_order.<root>.progress` (milestones; no `.milestone` suffix) | **MP-E1-C7** writes the producer; the module `Aiur.BuildProgress` belongs to the `build-orders` component and the queue is one of its producers (RC-08, RC-10, RC-40) | ledgered |
  | `system.capabilities.changed` | capability registry (MP-R1-C3-T05) | live; exported when `events.export` is on (attrs `revision`, `boot_id`); never bound to the Executor wake stream |
  | `system.executor.transcript.drift` | MP-E3-C2-T02 | ledgered |
  | `executor.conversation.*` | reserved, unused (MP-E3 uses the conversation contract) | — |

  Exact queue causes and payload allowlists: queue-readiness §4.3 (CR-E1-1).

  `ticket.<id>.agent.decision.*` stays DecisionStore-owned: MP-E2 adds slugs
  through DecisionStore, not new namespaces.
- **Attribution override (Phase D, CR-E7-1).** The IssueLog labels every
  `ticket.<id>.agent.*` event `:self` (`publisher.ex:339-352`). A catalog entry
  may declare `attribution: :payload_actor`; the IssueLog then takes the actor
  from the payload (`human`, `executor`, `system`). Only
  `ticket.<id>.agent.listen-mode.changed` uses it in v1. The topic keeps its
  RC-08 name (a rename would need a separately approved ticket, above).
- **Legacy topics outside the grammar.** The seven alert-name topics in §6
  (`ledgered`) are catalogued as such, never exported, and are not
  renamed by MP-R2 (DESIGN-R2 §1 "event names stay"); a rename is a
  signal-port (MP-R1-C5) decision recorded in
  `../bucket-1-refactor/MP-R2/tickets/CONTRACT-REQUESTS.md`.
- **Versioning**: `v` is the envelope major; it changes only with a new API
  path (`/api/v2/events`). `payload_version` per topic changes when an
  allowlisted field changes meaning or is removed; adding a field does not
  bump it. Clients ignore unknown fields and unknown topics. The server
  publishes the catalog (`GET /api/v1/events/catalog`) so clients detect what
  exists rather than assuming.

## 10. External subscriber API (proposed; C7)

| Surface | Shape |
| --- | --- |
| Pull | `GET /api/v1/events?after=<seq>&limit=<1..500>&topics=<pattern,…>` → `{instance, epoch, head_seq, oldest_seq, records:[…]}`; `after` older than `oldest_seq` → a single `reset` record. Declared inside the `:dashboard_auth` scope **before** `/api/v1/:issue_identifier/events` and `/api/v1/:issue_identifier` (`router.ex:186-199`), which would otherwise shadow it (RQ-7) |
| Catalog | `GET /api/v1/events/catalog` → exported topics, classes, payload versions |
| Live | Phoenix socket `/events`, channel `events:feed`, join `{after}`; server sends backlog then live records and a `heartbeat` every 25 s |
| CLI | `aiur events tail [--after] [--topic] [--json]` (only if DESIGN-R2 KQ-R2-2 approves) |
| Capability | `events.export` advertised in the Capabilities contract with `{v:1, retention}`; `unavailable/disabled` when `events.export.enabled: false` (MP-R2-C7-T03) |

Authorization and scope:

- Read-only. There is no publish endpoint for external clients; Commands are
  answered through the Decision API (MP-E2 contract), messages through the
  conversation API (MP-E4).
- Today: the existing `:dashboard_auth` pipeline (basic auth) and the
  loopback-by-default bind rules (MP-R3). `:dashboard_auth` never becomes an
  open pass-through: unconfigured credentials answer 401 or 503
  (`financial_data_access.ex:50-84`). Later: the paired-device bearer, which
  the Pairing contract accepts on every `:dashboard_auth` route (pairing
  §4.4, MP-N2-C6); revoking a device must also close its live `events:feed`
  channels (MP-R2-C7-T05). Being on the tailnet is never sufficient.
- Topic filters may only narrow the allowlisted catalog; a client cannot
  request a non-exported topic.
- The webhook pipeline (`/api/v1/github/webhook`, outside dashboard auth) is
  never used for the feed.

## 11. Scheduling and classification (RC-09, amended by RC-31)

The packaging chunks C1–C4 are Bucket 1 (behaviour-preserving). The catalog,
export journal and external API (C5–C7) are **Bucket-2-enabling work inside
MP-R2**: off by default (`events.export.enabled: false`), no user-facing
change while disabled. Scheduling (RC-31 amends RC-09):

- **C5 (topic catalog) runs at the start of wave 4**, because MP-E6-C4-T05 and
  MP-E7-C2-T05 consume it in wave 4.
- **C6 and C7 (export journal, external API) run in wave 5**, just before their
  first consumers MP-N4/MP-N5; C7 also precedes MP-N3's switch from polling to
  the stream.

MP-E1 v1 does not need C6 (queue-readiness E-A5). Like every MP-R2 ticket, C5–C7
wait for U0 review of the prior refactor plan (RC-19, X-58).

## 12. What each consumer gets (summary; details in plan.md §8)

| Consumer | Uses | Must not assume |
| --- | --- | --- |
| MP-E1 queue | In-BEAM Exchange subscription to `ticket.*.pr.merged`, `system.dispatch.*`; own reconciliation against tracker + build-order graph; publishes `ticket.<id>.queue.*` and (webhook mode) `ticket.<id>.pr.closed_unmerged` | That a merge event will arrive (it is `live` class); that its own reads need "closed unmerged" or "blocked_by changed" events (the queue reads the `:branch_pull_request` deposit and `blocked_by` through tracker callbacks, CR-E1-2) |
| MP-E2 Commands | DecisionStore stays truth; lifecycle topics exported as ids + version | That the feed carries Command text |
| MP-E3 Executor chat | `executor.*` journal for Executor events; conversation contract for chat | That chat lines are bus events |
| MP-E4 navigation | `id`, `occurred_at`, `refs.ticket`, reserved `anchor`; export journal as the durable per-ticket index for non-agent events. **Follow-up after MP-R2-C6** (CR-E4-7): a consumer-side ticket backfills anchors from `seq`, starting at the cursor MP-E4-C3-T02 stores in `resolver.json` | That IssueLog holds GitHub/CI/PR events (it does not, §6); that live events published while the daemon was down reach the resolver |
| MP-N3 meta-dashboard | `head_seq` + heartbeat for freshness; snapshots for counts | That a missing event means zero |
| MP-N4 push | Durable consumer (C3) on the export feed; `reset`/`gap` handling; resolution topics to clear | Immediate or guaranteed delivery |
| MP-N5 preferences | Exported topics as candidate signals; `observed_at` for staleness | That build-order % is an event today (it is PubSub-only) |
| MP-N6 response | `refs.decision_id` + `instance` to resolve the deep link | That a Command is still open; re-read before answering |
