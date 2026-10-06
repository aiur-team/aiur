---
ticket_id: MP-N5-C2-T01
feature_id: MP-N5
chunk_id: MP-N5-C2
bucket: 3-mobile-watch
title: Policy process — event Source adapter (export feed or live), dedup ledger, boot and gap reconciliation
status: ready
blocked_by: [DESIGN-N5 (no-UI release), MP-N5-C2-T00, MP-N4-C3-T02, MP-R2-C6-T04]
prior_units: []
prior_boundaries: [new #41 candidate push-relay, EXE #26 (listener pattern)]
prior_features: [MP-R2, MP-N4]
prior_findings: [events-and-replay §5 O-1 (ids are not delivery order), §6 D-1/D-2, §7.2 rule 6 (no burst after reconnect is N5's), RC-09]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N5-C2-T01 — Policy process, Source adapter, ledger, reconciliation

## Identity and outcome

Bucket 3, MP-N5, chunk C2. The foundation the rule tickets plug into:

1. `Aiur.Push.Policy.Server` (PROPOSED): one process per instance, started under
   `Aiur.Push.Supervisor` (MP-N4-C3-T04) after the outbox.
2. `Aiur.Push.Policy.Source` behaviour with two implementations (RC-09, PC-7):
   - `ExportFeed`: the MP-R2-C6 `DurableConsumer` named `push_policy`, replaying from its
     persisted `seq` cursor when `events.export.enabled: true`.
   - `Live`: `Aiur.Events.Exchange.subscribe/2` on the N5 topic patterns when the export
     journal is off.
3. `Aiur.Push.Policy.Ledger`: `(device_id, dedup_key)` set persisted at
   `<runtime_state_dir>/push/ledger.ndjson`; a key is written **in the same step** as
   `Outbox.accept/2` (ledger first, then accept; the accept is idempotent on `job_id`, so a
   crash between them yields at most a resend through the outbox, never a second intent).
4. Reconciliation: at boot, on a `gap`/`reset` record, and every 10 minutes, re-derive
   "needs you" Commands from `Aiur.DecisionStore.list/1` and progress facts from
   `Aiur.BuildQueue.progress/1`, feeding them through the same rules; the ledger absorbs
   repeats.
5. Rule dispatch: `rules :: [module]` implementing `Aiur.Push.Policy.Rule`
   (`handle_event/2`, `reconcile/2` → `[NotificationIntent]`); C2-T02..T04 add rules.

## Dependencies and blockers

- C2-T00 (names), MP-N4-C3-T02 (outbox), MP-R2-C6-T04 (DurableConsumer; if MP-R2-C6 is
  deferred, the `Live` source alone ships and `ExportFeed` waits — recorded in C2-T00).
- DESIGN-N5 no-UI release.

## Verified starting point

- `Exchange.subscribe(pattern)` delivers `{:event, event}` to the caller and reaps the
  binding when the subscriber dies (`src/lib/aiur/events/exchange.ex:60-108`).
- Ordering: per-publisher FIFO only; ids are not a delivery order (events-and-replay §5,
  O-1); `journaled` replay only for journaled/exported classes (§6 D-1).
- `Aiur.DecisionStore.list/1 :: [Decision.t()]` (`decision_store.ex:393`).
- `runtime_state_dir/0` (`config/paths.ex:243`; test override `:runtime_state_dir`).
- Re-ask loop `DecisionAttention` every 15 min (`decision_attention.ex:17`) publishes
  attention events that are **not** subscribed here (rule tickets assert this).

## Chosen design

- Topic patterns subscribed (Live): `ticket.*.agent.decision.*`, `executor.decision.*`,
  `system.build_order.*.progress.*`, `system.queue.*.progress.*`, `ticket.*.pr.merged`,
  `ticket.*.ci.failed`, `ticket.*.agent.retry_exhausted` (exact strings confirmed in
  C2-T00). The E1 progress-changed signal (RC-10) is subscribed through whatever internal
  interface MP-E1-C7 exposes (CR-N5-4 asks for its name/shape); the Source adapter hides it.
- Dedup on `(instance_id, event id)` inside a 10 000-entry LRU for the live path;
  cursor `seq` for the export path.
- Ledger retention: Command keys 30 days; progress keys until the scope generation ends;
  compaction like the outbox.
- No intent is generated for a device that has no valid registration (MP-N4 registry), so
  nothing accumulates to burst later (MP-N4 plan §7.1).

## Implementation steps

1. `policy/server.ex`, `policy/source.ex`, `policy/source/export_feed.ex`,
   `policy/source/live.ex`, `policy/ledger.ex`, `policy/rule.ex` (PROPOSED).
2. Reconciliation scheduler.
3. Tests with a fake Source, temp `runtime_state_dir`, injected clock.

## Non-happy paths

- Export enabled but the journal reports `reset` (cursor older than retention) → full
  reconciliation, cursor moved to head; no replay of the backlog as notifications
  (events-and-replay §7.2 rule 6).
- Policy crash → supervisor restart; reconciliation at boot covers the gap.
- DecisionStore unavailable at boot → retry with backoff; Commands are not dropped.

## Compatibility and rollout

Inert when `push.enabled: false` (the supervisor does not start it).

## Verification

`src/test/aiur/push/policy/server_test.exs` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"live and export sources yield identical intents for the same events"` | equal lists | special-case one source |
| `"duplicate delivery of one event id yields one intent"` | 1 | remove LRU dedup |
| `"crash between ledger write and accept yields one send"` (AC-N5-5) | fake relay 1 | accept before ledger write and lose idempotency |
| `"reset triggers reconciliation, not backlog notifications"` | intents only for currently open items | replay backlog |
| `"boot reconciliation enqueues a human_needed lost while down"` | 1 intent | skip boot reconcile |
| `"no registered device → no intents, nothing queued"` | 0 | queue for later |

Commands (from `src/`): `mise exec -- mix test test/aiur/push/policy/server_test.exs`.

## Completion and handoff

- [ ] Both sources tested; ledger ordering asserted.
- Dependents: C2-T02, C2-T03, C2-T04, C3-*.
