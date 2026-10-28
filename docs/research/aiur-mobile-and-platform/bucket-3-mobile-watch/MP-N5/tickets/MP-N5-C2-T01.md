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
   - `Live`: `Aiur.Events.subscribe/1,2` on the N5 topic patterns when the export
     journal is off.
3. `Aiur.Push.Policy.Ledger`: `(device_id, dedup_key)` set persisted at
   `<runtime_state_dir>/push/ledger.ndjson`; a key is written **in the same step** as
   `Outbox.accept/2` (ledger first, then accept; the accept is idempotent on `job_id`, so a
   crash between them yields at most a resend through the outbox, never a second intent).
4. Reconciliation: at boot, on a `gap`/`reset` record, and every 10 minutes, re-derive
   "needs you" Commands from `Aiur.Commands.list_decisions/0,1,2` and progress facts from
   `Aiur.BuildProgress.facts/1`, feeding them through the same rules; the ledger absorbs
   repeats.
5. Rule dispatch: `rules :: [module]` implementing `Aiur.Push.Policy.Rule`
   (`handle_event/2`, `reconcile/2` → `[NotificationIntent]`); C2-T02..T04 add rules.

## Dependencies and blockers

- C2-T00 (names), MP-N4-C3-T02 (outbox), MP-R2-C6-T04 (DurableConsumer; MP-R2-C6 has
  landed; `Live` is the fallback when export is disabled or unavailable).
- DESIGN-N5 no-UI release.

## Verified starting point

Path refresh at `3b00b8f2cd0bfc9acdffe3b07ee5f1c6ca2ab56a` (2026-10-27).
See [plan §10](../plan.md#10-notification-policy-starting-point) for the complete
mapping, topic catalog and integration gates. Historical `base_sha` is retained.
All `policy/**`, `Aiur.Push.*` and push test paths here are **PROPOSED** under
`push-relay`; this refresh does not assert they shipped.

- Subscribe through public `Aiur.Events.subscribe/1,2` (`src/lib/aiur/events.ex:23-27`),
  receiving `{:event, event}`; Exchange is private.
- Use `Aiur.Events.DurableConsumer.start_link/1` and `ExportSource`, not a proposed
  Consumer `replay/1`. Source `replay/3` and handler reset/gap semantics are in plan §10.
  Handler behaviour visibility awaits CR-N5-PATH-3.
- Reconcile Commands with public `Aiur.Commands.list_decisions/0,1,2`
  (`src/lib/aiur/commands.ex:182-190`). Progress reads/subscription await CR-N5-PATH-2.
- Runtime directory accessor is now `src/lib/aiur/config/paths.ex:329`;
  its use awaits CR-N4-PATH-1. Re-asks remain 15 min (`decision_attention.ex:20`).

## Chosen design

- Topic patterns subscribed (Live): `ticket.*.agent.decision.*`, `executor.decision.*`,
  `system.build_order.*.progress`, `system.queue.*.progress`, `ticket.*.pr.merged`,
  `ticket.*.ci.failed`, `ticket.*.agent.retry_exhausted` (exact strings confirmed in
  C2-T00). The E1 progress-changed signal (RC-10) is subscribed through the landed
  interface, pending CR-N5-PATH-2 approval (`Aiur.BuildProgress.subscribe/0`, PubSub `"build_progress"`, message `{:build_progress_changed, fact}`, queue-readiness contract §4.0; CR-N5-4 closed in Phase D); the Source adapter hides it.
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
  reconciliation, consumer resumes at `oldest - 1` and replays retained records; policy suppresses
  historical intents during catch-up (plan §10), with no backlog notifications
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
- Docs: none — internal policy server with no operator surface; the user-visible
  behaviour it enables is documented by C2-T02/C2-T03 and C5-T01 (Phase D T-6).
- Dependents: C2-T02, C2-T03, C2-T04, C3-*.
