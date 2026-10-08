# MP-R2-ACC — MP-R2 acceptance QA

**Complexity:** 2
**Kind:** feature acceptance capstone (Executor-owned QA)
**Depends on:** MP-R2-C1-T03, MP-R2-C1-T04, MP-R2-C4-T04, MP-R2-C4-T05, MP-R2-C5-T03, MP-R2-C6-T04, MP-R2-C6-T05, MP-R2-C7-T03, MP-R2-C7-T04, MP-R2-C7-T05

## Outcome

The Executor proves MP-R2 end to end on current main and records the evidence.

## Scope

- Rebuild and restart the daemon from current main; confirm the loaded build.
- Run the feature's own acceptance criteria from its plan in the research pack (`docs/research/aiur-mobile-and-platform/**/MP-R2/`).
- Drive the real surfaces (CLI, dashboard, TUI, device) as AGENTS.md "Manual testing" defines it; capture screenshots or pane captures.
- File P0/P1 acceptance blockers against the owning ticket; put P2/P3 findings in the deferred ledger.

## Members covered (38)

- MP-R2-C1-T01 — Characterize which published events reach the per-ticket IssueLog event history
- MP-R2-C1-T02 — Witness whether an out-of-order lower event id is dropped by per-ticket and Executor consumers
- MP-R2-C1-T03 — Witness that non-executor wakes published while ExecutorListener is unbound are not replayed
- MP-R2-C1-T04 — Pin bus supervision order and re-bind after an Exchange restart
- MP-R2-C1-T05 — Enforce the placement rule — topic prefixes and the Exchange-to-PubSub bridge allowlist
- MP-R2-C1-T06 — Record today's outbound dependencies of the event-bus members as a shrinking allowlist
- MP-R2-C2-T01 — Aiur.Events.Delivery behaviour for per-ticket delivery and dead-letter reporting
- MP-R2-C2-T02 — Aiur.Events.TrustClassifier behaviour that consumes U5's single KTD9 trust snapshot
- MP-R2-C2-T03 — Aiur.Events.HistoryStore write sink for per-ticket event markers
- MP-R2-C2-T04 — Route Webhooks.EventSource's default publish through the Publisher boundary (RQ-6)
- MP-R2-C2-T05 — Put the debug event mirror behind an optional trace sink (no Phoenix.PubSub in the bus core)
- MP-R2-C2-T06 — Move the Publisher's GitHub-specific gates behind an Aiur.Events.SourcePolicy behaviour, gate order unchanged
- MP-R2-C2-T07 — Inject the IdGenerator's cold-boot floor sources from app boot (no Executor/launch-state edges in the bus)
- MP-R2-C2-T08 — Aiur.Events facade and caller migration batch A (ingestion producers)
- MP-R2-C2-T09 — Aiur.Events facade migration batch B (orchestration)
- MP-R2-C2-T10 — Aiur.Events facade migration batch C (commands, Executor, alerts, projections, agent runner)
- MP-R2-C2-T11 — Assign the non-bus modules under events/ to their owning components in components.json (no file moves)
- MP-R2-C3-T01 — Aiur.Events.Journal, a thin facade over Aiur.DecisionLog with an injected corrupt-tail reporter; ExecutorEvents uses it
- MP-R2-C3-T02 — Extract the reserve → append → publish sequence into Aiur.Events.publish_journaled/3; ExecutorEvents calls it
- MP-R2-C3-T03 — Aiur.Events.DurableConsumer — subscribe, replay from a persisted cursor, then live, at-least-once (not wired)
- MP-R2-C4-T01 — Finalize the logical event-bus component in components.json (paths, narrowed facades, owned config and state); no Mix app, no file moves
- MP-R2-C4-T03 — Swap the temporary bus boundary test for MP-R1's checker rule, and run the packaging acceptance (full suite on the merge ref + real aiurdev --test)
- MP-R2-C4-T04 — Refresh MP-R2 tickets and consumer citations after C1–C4 merge (with MP-R1-C11)
- MP-R2-C4-T05 — Document the bus placement rule and durability classes in concepts/message-bus.md (existing behaviour only)
- MP-R2-C5-T01 — Aiur.Events.Catalog — code-level topic registry (class, export flag, allowlists, payload_version, owner) for every topic published today
- MP-R2-C5-T02 — Aiur.Events.Envelope.to_external/2 — pure, allowlist-only serializer to external envelope v1
- MP-R2-C5-T03 — Reserve planned namespaces and register the RC-08 topics in the catalog (owners, classes, allowlists)
- MP-R2-C5-T04 — Instance identity provider for exported envelopes (instance_id from MP-R1 Identity; feed unavailable when identity is degraded)
- MP-R2-C6-T01 — Config keys events.export.enabled, events.export.retention_days, events.export.retention_max_events with docs rows
- MP-R2-C6-T02 — Export journal writer — single exporter process, dense seq, gap on start, corrupt tail → unavailable + one attention, end-of-tree placement
- MP-R2-C6-T03 — Export retention by whole-segment deletion, oldest_seq/head_seq meta, and epoch rules (new epoch only when the journal is re-created or the instance changes)
- MP-R2-C6-T04 — ExportSource — DurableConsumer source over the export journal (replay by seq, live by append notification, reset/unavailable mapping)
- MP-R2-C6-T05 — Exporter back-pressure alarm sized from a measured export-rate census (RQ-4), with a fixed sizing rule and fsync-batching trigger
- MP-R2-C7-T01 — Pull API GET /api/v1/events and GET /api/v1/events/catalog over the export journal (off by default)
- MP-R2-C7-T02 — Live feed — /events socket, events:feed channel, short-lived token, backlog then live, 25 s heartbeat
- MP-R2-C7-T03 — Advertise the events.export capability {v, retention} through the MP-R1 capability registry
- MP-R2-C7-T04 — Operator CLI aiur events tail and the aiur status EVENTS line (only if DESIGN-R2 S2/S3 approve)
- MP-R2-C7-T05 — Paired-device access to the event feed — device bearer for the events token, revocation closes live channels

## Acceptance and verification

- Every member above is merged.
- The feature's acceptance criteria pass on current main, with dated evidence.
