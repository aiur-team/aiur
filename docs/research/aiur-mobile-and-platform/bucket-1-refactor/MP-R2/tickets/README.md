# MP-R2 remaining tickets

Refreshed 2026-10-25 against `761756f394e6783794c777668fc1a26a540e4059`.

C1–C4 are merged. These fourteen C5–C7 tickets retain their original researched
date and decisions, with current starting points and U8 size-owner checks.
C7-T04 remains blocked on RQ-REFRESH-CLI-1 for its obsolete CLI extraction design.

| Ticket | Outcome |
| --- | --- |
| [MP-R2-C5-T01](MP-R2-C5-T01.md) | Aiur.Events.Catalog — code-level topic registry (class, export flag, allowlists, payload_version, owner) for every topic published today |
| [MP-R2-C5-T02](MP-R2-C5-T02.md) | Aiur.Events.Envelope.to_external/2 — pure, allowlist-only serializer to external envelope v1 |
| [MP-R2-C5-T03](MP-R2-C5-T03.md) | Reserve planned namespaces and register the RC-08 topics in the catalog (owners, classes, allowlists) |
| [MP-R2-C5-T04](MP-R2-C5-T04.md) | Instance identity provider for exported envelopes (instance_id from MP-R1 Identity; feed unavailable when identity is degraded) |
| [MP-R2-C6-T01](MP-R2-C6-T01.md) | Config keys events.export.enabled, events.export.retention_days, events.export.retention_max_events with docs rows |
| [MP-R2-C6-T02](MP-R2-C6-T02.md) | Export journal writer — single exporter process, dense seq, gap on start, corrupt tail → unavailable + one attention, end-of-tree placement |
| [MP-R2-C6-T03](MP-R2-C6-T03.md) | Export retention by whole-segment deletion, oldest_seq/head_seq meta, and epoch rules (new epoch only when the journal is re-created or the instance changes) |
| [MP-R2-C6-T04](MP-R2-C6-T04.md) | ExportSource — DurableConsumer source over the export journal (replay by seq, live by append notification, reset/unavailable mapping) |
| [MP-R2-C6-T05](MP-R2-C6-T05.md) | Exporter back-pressure alarm sized from a measured export-rate census (RQ-4), with a fixed sizing rule and fsync-batching trigger |
| [MP-R2-C7-T01](MP-R2-C7-T01.md) | Pull API GET /api/v1/events and GET /api/v1/events/catalog over the export journal (off by default) |
| [MP-R2-C7-T02](MP-R2-C7-T02.md) | Live feed — /events socket, events:feed channel, short-lived token, backlog then live, 25 s heartbeat |
| [MP-R2-C7-T03](MP-R2-C7-T03.md) | Advertise the events.export capability {v, retention} through the MP-R1 capability registry |
| [MP-R2-C7-T04](MP-R2-C7-T04.md) | Operator CLI `aiur events tail` and the `aiur status` EVENTS line (only if DESIGN-R2 S2/S3 approve) |
| [MP-R2-C7-T05](MP-R2-C7-T05.md) | Paired-device access to the event feed — device bearer for the events token, revocation closes live channels |

See the [refresh audit](../../../refresh/MP-R2-C4-T04.md) for source evidence,
and [CONTRACT-REQUESTS](CONTRACT-REQUESTS.md) for foreign-owner corrections.

Earlier ticket and inventory research remains available at
[the pinned research tree](https://github.com/aiur-team/aiur/tree/6732f5f9f448b1857a9643993849635f85321e19/docs/research/aiur-mobile-and-platform/bucket-1-refactor/MP-R2).
