# MP-R2 contract requests (for the coordinator)

MP-R2 owns `contracts/events-and-replay.md` and updated it directly. The
items below need a change in an artifact MP-R2 does **not** own. Each names
the owner, the evidence at `45a290e3` and the MP-R2 ticket that waits on it.

| ID | Owner | Artifact | Request | Evidence | Waiting ticket |
| --- | --- | --- | --- | --- | --- |
| CR-R2-1 | MP-R1 | `bucket-1-refactor/MP-R1/component-map.md` (event-bus row `:92`, github-listeners `:102`) and the `components.json` it seeds (MP-R1-C1-T01) | (a) Do **not** list `debug_log.ex` in `event-bus`; after MP-R2-C2-T05 it is the default trace implementation and belongs to `tui`. (b) Assign `events/sanitizer.ex`, `events/branch_ref_store.ex`, `events/comment_filter.ex` to `github-listeners`; `event_publication_log.ex` to `agent-runner`. (c) Add the new bus modules (`events.ex`, `events/{delivery,history_store,trace,source_policy,trust_classifier}.ex`, later `journal`, `durable_consumer`, `catalog`, `envelope`, `export/*`) to `event-bus`. (d) Add `Aiur.IdFloorSources` and the default adapters (`Aiur.Orchestrator.EventDelivery` → orchestration, `Aiur.IssueLog.EventHistorySink` → agent-runner, `Aiur.GitHub.EventTrust`, `Aiur.GitHub.EventSourcePolicy` → github) to their components. | caller census in MP-R2-C2-T11 | MP-R2-C2-T11, MP-R2-C4-T01 |
| CR-R2-2 | MP-R1 | component-map (layer rules) | `Aiur.TicketObservation` (event-bus, L1) references `Aiur.TrackerIdentity` and `Aiur.OpaqueIdentifier` (tracker types). Decide: move these value types to kernel, or allow the `event-bus → tracker` type edge. No C2 ticket removes it. | `ticket_observation.ex:50-62`; MP-R2-C1-T06 | MP-R2-C4-T03 (checker rule) |
| CR-R2-3 | MP-R1 (signal port, MP-R1-C5-T03) | signal-port design | `Aiur.Alerts` publishes every alert name as an Exchange topic, so seven topics exist outside the `ticket.`/`system.`/`executor.` grammar (e.g. `decision_store.corrupted`, `executor_events.corrupted`; full list in MP-R2-C1-T05). MP-R2 catalogs them as `ledgered`, never exported, and does not rename them (DESIGN-R2 §1). If `Signal.emit/2` should map them into `system.*`, that is a topic rename and needs its own owner approval. | `alerts.ex:144-152,293-313` | none (MP-R2 proceeds with the classification) |
| CR-R2-4 | MP-R1 | `contracts/identity-and-capabilities.md` §2 reasons | Add reasons `identity_degraded` (instance has no `instance_id`; the exporter refuses to start) and `journal_corrupt` (export journal corrupt tail, feed stopped) for `events.export`, or confirm mappings onto existing reasons (`dependency_unavailable` with `depends_on: ["identity"]`). | events-and-replay §3 | MP-R2-C7-T03 |
| CR-R2-5 | MP-N2 | `contracts/pairing-and-instance-registry.md` §4.4 / MP-N2-C7 | Revocation must reach live WebSocket channels, not only the next HTTP request: after the store write in revoke and unpair-all (MP-N2-C7-T01), broadcast `{:devices_revoked, [device_id]}` on PubSub topic `devices:revoked` so `events:feed` channels bound to that `device_id` close. Without it, a revoked device keeps receiving identifier-only events for up to the 300 s token lifetime. Today device tokens are checked per request by store mtime. | pairing §4.4 ("a revoked device fails on the next request") | MP-R2-C7-T05 |
| CR-R2-6 | MP-E1 | `contracts/queue-readiness-and-build-progress.md` §6 E-A3 | RC-08 settles that MP-R2's catalog registers `ticket.<id>.pr.closed_unmerged` and `ticket.<id>.issue.closed`; the **producer** is MP-E1 (in the ingestion normalizer and poll path), not MP-R2. Update E-A3 from "Requested" to "Registered by MP-R2-C5-T03; produced by MP-E1-C4". | RC-08 | MP-R2-C5-T03 (registration only) |

## MP-R2-C1-T05 implementation census (2026-10-08)

Re-resolved against `2d8ca3198` for signal-port owner MP-R1-C5-T03 (CR-R2-3).
The seven researched violations remain, with one additional pre-existing topic.
All eight stay unchanged under DESIGN-R2 §1 and are explicit shrinking exceptions
in `src/test/aiur/events/placement_rule_test.exs`:

| Source under `src/lib/aiur/` | Topic |
| --- | --- |
| `decision_store.ex:697` | `decision_store.unrecognized_event_types` |
| `decision_store.ex:719` | `decision_store.corrupted` |
| `decision_store/projection_recovery.ex:117` | `decision_store.repair_failed` (moved since research) |
| `decision_store.ex:2594` | `decision_store.append_ambiguous` (added since research) |
| `executor_events.ex:468` | `executor_events.corrupted` |
| `github/dispatch_authorization.ex:740` | `github.dispatch_authorization.ambiguous` |
| `github/dispatch_authorization.ex:755` | `github.dispatch_authorization.timeline_unreadable` |
| `orchestrator/retry_engine.ex:1219` | `orchestrator.claim_released` |

The direct Exchange-to-PubSub bridges are `Aiur.TicketActivity`,
`Aiur.BuildOrder.TicketHistoryProvider` (including its options file), and
`Aiur.DecisionMetrics`, plus `Aiur.BuildQueue.Server` (added since research). The metrics wrapper is now
`DecisionPubSub.broadcast_metrics_changed/0`, recognized alongside
`broadcast_changed`. Function captures such as `&Exchange.subscribe/1` also
count as subscriptions. No direct PubSub-to-Exchange bridge was found; its
allowlist is empty. This is a source census, not the runtime catalog census.

The research pack is absent from this integration checkout; this file preserves
the coordinator's requests from `6732f5f9f448b1857a9643993849635f85321e19` and
appends only this implementation audit.

## C4-T04 consumer refresh (2026-10-25)

Target: `761756f394e6783794c777668fc1a26a540e4059`; source pack: `6732f5f9f448b1857a9643993849635f85321e19`.
DESIGN-R2 approval is recorded at `9ce9fdc6` in EXECUTOR-APPROVALS.md.
The [audit](../../../refresh/MP-R2-C4-T04.md) supplies current symbols and ten exact ranges.
The original CR-R2-1..6 and 2026-10-08 census above are historical requests;
current ownership is in components/*.json. CR-R2-2 is resolved: tracker value
types are kernel-owned and the event-bus requires kernel/config only.

Foreign contracts are not edited here. Coordinator corrections:

| Owner | Artifact | Exact correction |
| --- | --- | --- |
| MP-E1 | contracts/queue-readiness-and-build-progress.md §6 E-A3/E-A5 | No physical aiur_events package; use Events.subscribe/1. C5 catalog and C6 export remain future; keep queue snapshot reconciliation. |
| MP-E2 | contracts/command-request-and-resolution.md:112 | ExecutorEvents.publish_requested/1 remains domain-owned; generic persist-before-publish moved to JournaledPublish.publish/3. |
| MP-E7 | contracts/listener-mode.md | Delivery.enqueue/3 and dead_letter/5 are the implemented port; orchestrator adapter owns the call. Publish mode events through Events.publish/3, preserving actor attribution. |
| MP-E4 | contracts/conversations-transcripts-anchors.md:35,425 | Cite current IdGenerator and Events.subscribe/1–2. HistoryStore.record/3 has no read API; event_history/2 stays IssueLog. Durable export/anchor backfill remains future C6. |
| MP-N4 | contracts/notification-destination-and-payload.md | DurableConsumer exists; ExportSource is C6-T04. Use seq for replay, (instance,id) for dedupe; no external feed has landed. |
| MP-R1 | contracts/identity-and-capabilities.md:159 | Use Events.publish/3; Identity.instance_id/0 and Capabilities.Provider are now implemented. No separate event-bus Mix application. |

The five named consumer plan/chunk files are refreshed in this PR. Other
consumer tickets remain owner-maintained; apply the corrections below to
unstarted tickets, or post them on the active PR when an owner has started.
Line numbers below identify the immutable **research documents**, not current
source code. Build-order ticket copies mirror these same ticket IDs and need
the same corrections in the coordinator's per-wave sweep (MP-R1-C11-T02).

| Owner | Research artifact | Research lines | Correction |
| --- | --- | --- | --- |
| MP-R1 | `bucket-1-refactor/MP-R1/component-map.md` | 93,104,166,170 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-R1 | `bucket-1-refactor/MP-R1/migration-plan.md` | 73,89,100 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-R1 | `bucket-1-refactor/MP-R1/tickets/MP-R1-C3-T01.md` | 53,100,140 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-R1 | `bucket-1-refactor/MP-R1/tickets/MP-R1-C3-T05.md` | 27,42 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-R1 | `bucket-1-refactor/MP-R1/tickets/MP-R1-C8-T01.md` | 71,130 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-R1 | `bucket-1-refactor/MP-R1/tickets/MP-R1-C8-T06.md` | 75 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-R1 | `bucket-1-refactor/MP-R1/tickets/MP-R1-C9-T01.md` | 91,202 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-R1 | `bucket-1-refactor/MP-R1/tickets/MP-R1-C9-T02.md` | 78,151 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-R1 | `bucket-1-refactor/MP-R1/tickets/MP-R1-C9-T03.md` | 13,59,80,142 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-R1 | `bucket-1-refactor/MP-R1/tickets/MP-R1-C9-T04.md` | 55,56,100 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-R6 | `bucket-1-refactor/MP-R6/plan.md` | 181 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| contract owner | `bucket-1-refactor/U-units/tickets/U3-T01.md` | 35,45,56,96 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| contract owner | `bucket-1-refactor/U-units/tickets/U5-T02.md` | 62,64,128,135 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| contract owner | `bucket-1-refactor/U-units/tickets/U5-T03.md` | 43 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| contract owner | `bucket-1-refactor/U8/README.md` | 169,170,171,251 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| contract owner | `bucket-1-refactor/U8/tickets/U8-P21-T01.md` | 60,61,62,63,65,66,83,92,93,94,95,96,98 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| contract owner | `bucket-1-refactor/U8/tickets/U8-P21-T02.md` | 56,57,58,59,60,80,81,82,83,84,85 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| contract owner | `bucket-1-refactor/U8/tickets/U8-P21-T03.md` | 64,65,66,79,98,99,100,101,102,107 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| contract owner | `bucket-1-refactor/U8/tickets/U8-P22-T01.md` | 85 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| contract owner | `bucket-1-refactor/U8/tickets/U8-P31-T02.md` | 79,156 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-E1 | `bucket-2-platform/MP-E1/chunks.md` | 248,283 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-E1 | `bucket-2-platform/MP-E1/findings.md` | 66,67,165,173 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-E1 | `bucket-2-platform/MP-E1/plan.md` | 443 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-E1 | `bucket-2-platform/MP-E1/tickets/MP-E1-C2-T04.md` | 50 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-E1 | `bucket-2-platform/MP-E1/tickets/MP-E1-C3-T03.md` | 21,51,54 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-E1 | `bucket-2-platform/MP-E1/tickets/MP-E1-C3-T06.md` | 38 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-E1 | `bucket-2-platform/MP-E1/tickets/MP-E1-C4-T05.md` | 40,44,66 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-E1 | `bucket-2-platform/MP-E1/tickets/MP-E1-C5-T01.md` | 47 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-E1 | `bucket-2-platform/MP-E1/tickets/MP-E1-C5-T03.md` | 38,72 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-E2 | `bucket-2-platform/MP-E2/plan.md` | 105 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-E2 | `bucket-2-platform/MP-E2/tickets/MP-E2-C1-T03.md` | 50 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-E2 | `bucket-2-platform/MP-E2/tickets/MP-E2-C6-T02.md` | 55,75,93 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-E3 | `bucket-2-platform/MP-E3/plan.md` | 47 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-E4 | `bucket-2-platform/MP-E4/chunks.md` | 94 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-E4 | `bucket-2-platform/MP-E4/plan.md` | 66,73,235,236 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-E4 | `bucket-2-platform/MP-E4/tickets/MP-E4-C3-T02.md` | 41,42,52,53 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-E4 | `bucket-2-platform/MP-E4/tickets/MP-E4-C3-T03.md` | 38,41 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-E4 | `bucket-2-platform/MP-E4/tickets/MP-E4-C4-T01.md` | 49,50 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-E6 | `bucket-2-platform/MP-E6/plan.md` | 36 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-E6 | `bucket-2-platform/MP-E6/tickets/MP-E6-C4-T05.md` | 38,39 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-E7 | `bucket-2-platform/MP-E7/tickets/MP-E7-C2-T05.md` | 30,43,54 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-E8 | `bucket-2-platform/MP-E8/baseline.md` | 314 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-E8 | `bucket-2-platform/MP-E8/tickets/MP-E8-C11-T04.md` | 57,198,201,218,274,351,474 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-E8 | `bucket-2-platform/MP-E8/tickets/MP-E8-C4-T03.md` | 110 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-E8 | `bucket-2-platform/MP-E8/tickets/MP-E8-C4-T04.md` | 105 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-E8 | `bucket-2-platform/MP-E8/tickets/MP-E8-C6-T02.md` | 142,146 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-N4 | `bucket-3-mobile-watch/MP-N4/plan.md` | 67,69 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-N4 | `bucket-3-mobile-watch/MP-N4/tickets/MP-N4-C3-T00.md` | 44 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-N5 | `bucket-3-mobile-watch/MP-N5/plan.md` | 58,63 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-N5 | `bucket-3-mobile-watch/MP-N5/tickets/MP-N5-C2-T00.md` | 28 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-N5 | `bucket-3-mobile-watch/MP-N5/tickets/MP-N5-C2-T01.md` | 29,50,51 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-N5 | `bucket-3-mobile-watch/MP-N5/tickets/MP-N5-C2-T02.md` | 69 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-N5 | `bucket-3-mobile-watch/MP-N5/tickets/MP-N5-C2-T04.md` | 44 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-E2 | `contracts/command-request-and-resolution.md` | 112 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| MP-E4 | `contracts/conversations-transcripts-anchors.md` | 35,343,355,425 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |
| contract owner | `contracts/events-and-replay.md` | 46,184,218,246,292 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| MP-R1 | `contracts/identity-and-capabilities.md` | 159 | Use Events facade; SourcePolicy/GitHub.EventSourcePolicy owns gates; see audit seam map. |
| contract owner | `contracts/queue-readiness-and-build-progress.md` | 249 | Use audit seam map; history reads stay IssueLog; seq is the durable cursor. |

### RQ-REFRESH-CLI-1 (MP-R2-C7-T04, CLI owner)

The specified StatusHeaderLines extraction targets deleted monolith functions.
Reconcile it with orchestrator/status_cli and executor_attention/cli before
implementation. The ticket stays blocked on this named RQ; this documentation
refresh does not redesign the CLI. This is planning drift from the CLI split,
not evidence of an event-bus production regression.
