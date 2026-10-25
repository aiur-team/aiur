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
