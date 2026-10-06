# MP-R2 tickets — standalone shared event bus

Base `45a290e3`, researched 2026-10-06. Plan: [../plan.md](../plan.md) (Phase C
changes in §12). Chunks: [../chunks.md](../chunks.md). Owned contract:
[../../../contracts/events-and-replay.md](../../../contracts/events-and-replay.md).
Owner gate: [DESIGN-R2](../../../owner-design-tasks/DESIGN-R2.md). Requests to
other owners: [CONTRACT-REQUESTS.md](CONTRACT-REQUESTS.md).

**Every ticket is blocked by DESIGN-R2** (§1 for C1–C4, §2 for C5–C7) **and
waits for the U0 review of the prior refactor plan** (RC-19; plan §4.5). U0 has
no ticket ID, so it is not in `blocked_by`; this applies to C5–C7 too.
`ready` means: no other blocker than DESIGN-R2 and earlier MP-R2 tickets.
`blocked` means: also waits on a prior unit, another feature, or an owner
answer (KQ). C1–C4 are Bucket 1; C5–C7 are Bucket-2-enabling and off by default.
C5 (topic catalog) ships at the **start of wave 4**, because MP-E6-C4-T05
and MP-E7-C2-T05 consume it there (RC-31, amending RC-09). C6 and C7 stay
just before MP-N4/MP-N5 in wave 5 (C7 before MP-N3's stream switch) (RC-09).

## Ticket table

| ID | Title | Status | External blockers (besides DESIGN-R2) | Wave |
| --- | --- | --- | --- | --- |
| [C1-T01](MP-R2-C1-T01.md) | IssueLog persistence matrix (RQ-1 witness) | ready | — | 1 |
| [C1-T02](MP-R2-C1-T02.md) | Out-of-order id witness → U3 (RQ-2) | ready | — | 1 |
| [C1-T03](MP-R2-C1-T03.md) | Executor wake gap witness (F5) | ready | — | 1 |
| [C1-T04](MP-R2-C1-T04.md) | Supervision order + Exchange crash re-bind | ready | — | 1 |
| [C1-T05](MP-R2-C1-T05.md) | Placement-rule test (prefixes, bridges) | ready | — | 1 |
| [C1-T06](MP-R2-C1-T06.md) | Boundary ratchet test `bus_boundary_test.exs` | ready | — | 1 |
| [C2-T01](MP-R2-C2-T01.md) | `Delivery` behaviour (enqueue + dead letter) | blocked | **U3 event-delivery fix** (`events-webhooks-executor-01`) | 3 |
| [C2-T02](MP-R2-C2-T02.md) | `TrustClassifier` over U5's KTD9 snapshot | blocked | **U5** (RC-21) | 3 |
| [C2-T03](MP-R2-C2-T03.md) | `HistoryStore` write sink | ready | — | 2 |
| [C2-T04](MP-R2-C2-T04.md) | `Webhooks.EventSource` default via Publisher (RQ-6) | ready | — | 2 |
| [C2-T05](MP-R2-C2-T05.md) | Debug mirror behind `Trace` sink | ready | — | 2 |
| [C2-T06](MP-R2-C2-T06.md) | Publisher GitHub gates → `SourcePolicy` | ready | — (rebase on U5 if it changes ResourceStore) | 2 |
| [C2-T07](MP-R2-C2-T07.md) | IdGenerator floor sources from boot | ready | — | 2 |
| [C2-T08](MP-R2-C2-T08.md) | `Aiur.Events` facade + batch A (ingestion) | ready | — | 3 |
| [C2-T09](MP-R2-C2-T09.md) | Facade batch B (orchestration) | ready | — | 4 |
| [C2-T10](MP-R2-C2-T10.md) | Facade batch C (commands, Executor, alerts, projections, runner) | ready | — | 4 |
| [C2-T11](MP-R2-C2-T11.md) | Manifest reassignment of non-bus modules | blocked | MP-R1-C1-T01, CR-R2-1 | 4 |
| [C3-T01](MP-R2-C3-T01.md) | `Aiur.Events.Journal` over DecisionLog | ready | — | 2 |
| [C3-T02](MP-R2-C3-T02.md) | `publish_journaled/3` from ExecutorEvents | ready | — | 3 |
| [C3-T03](MP-R2-C3-T03.md) | `DurableConsumer` (not wired) | ready | — | 3 |
| [C4-T01](MP-R2-C4-T01.md) | Register `event-bus` in `components.json` | blocked | MP-R1-C1-T01/T03 | 5 |
| — C4-T02 | absorbed by MP-R1-C4 (events section) | — | — | — |
| [C4-T03](MP-R2-C4-T03.md) | Checker gate + full CI + manual `aiurdev --test` acceptance | blocked | MP-R1-C1-T03/T05 | 6 |
| [C4-T04](MP-R2-C4-T04.md) | Plan refresh of citations | blocked | MP-R1-C11-T01 | 7 |
| [C4-T05](MP-R2-C4-T05.md) | Docs: `concepts/message-bus.md` | ready | — | 2 |
| [C5-T01](MP-R2-C5-T01.md) | `Events.Catalog` | blocked | KQ-R2-3 | B2-a |
| [C5-T02](MP-R2-C5-T02.md) | `Envelope.to_external/2` | ready | — | B2-b |
| [C5-T03](MP-R2-C5-T03.md) | RC-08 topic registrations | ready | — | B2-b |
| [C5-T04](MP-R2-C5-T04.md) | `instance_id` provider adapter | blocked | MP-R1-C2-T01/T02 | B2-c |
| [C6-T01](MP-R2-C6-T01.md) | `events.export.enabled` / `.retention` keys + docs | blocked | KQ-R2-1 (S1) | B2-a |
| [C6-T02](MP-R2-C6-T02.md) | Exporter process (last child, gap, corrupt tail) | ready | — | B2-d |
| [C6-T03](MP-R2-C6-T03.md) | Retention + `export.meta.json` | ready | — | B2-e |
| [C6-T04](MP-R2-C6-T04.md) | DurableConsumer over export journal | ready | — | B2-f |
| [C6-T05](MP-R2-C6-T05.md) | Mailbox alarm (RQ-4 census + rule) | ready | — | B2-f |
| [C7-T01](MP-R2-C7-T01.md) | `GET /api/v1/events` + `/catalog` | ready | — | B2-f |
| [C7-T02](MP-R2-C7-T02.md) | `/events` socket + `events:feed` channel | ready | — | B2-g |
| [C7-T03](MP-R2-C7-T03.md) | `events.export` capability | blocked | MP-R1-C3-T01 | B2-g |
| [C7-T04](MP-R2-C7-T04.md) | `aiur events tail` + status line | blocked | KQ-R2-2, S2/S3 | B2-g |
| [C7-T05](MP-R2-C7-T05.md) | Paired-device tokens; revocation closes channels | blocked | MP-N2-C6, MP-N2-C7, DESIGN-N2, CR-R2-5 | B2-h |

Counts: 38 tickets — C1 6, C2 11, C3 3, C4 4, C5 4, C6 5, C7 5.
26 ready, 12 blocked.

## Dependency order

```text
C1-T01..T06 (all independent)
  ├─► C2-T03, C2-T04, C2-T05, C2-T06, C2-T07, C3-T01, C4-T05      (wave 2)
  ├─► C2-T01 (after U3) ; C2-T02 (after U5)                         (wave 3)
  ├─► C2-T08 (after T04, T06) ; C3-T02, C3-T03 (after C3-T01)       (wave 3)
  └─► C2-T09, C2-T10 (after T08) ; C2-T11 (after T05, MP-R1-C1-T01)  (wave 4)
C2-* + C3-T01/T02 + MP-R1-C1 ─► C4-T01 ─► C4-T03 ─► C4-T04        (waves 5–7)

Bucket-2-enabling (C5 at the start of wave 4, RC-31; C6/C7 before MP-N4/N5):
C5-T01 (KQ-R2-3) ─► C5-T02, C5-T03 ; C5-T02 + MP-R1-C2 ─► C5-T04
C6-T01 (KQ-R2-1) + C5-T02/T04 + C3-T01 + C2-T07/T08 ─► C6-T02 ─► C6-T03 ─► C6-T04 (+C3-T03), C6-T05
C6-T02/T03 + C5-T01/T02 ─► C7-T01 ─► C7-T02 ─► C7-T05 (MP-N2-C6/C7)
C7-T01 ─► C7-T03 (MP-R1-C3-T01), C7-T04 (KQ-R2-2)
```

## What may run concurrently

- All six C1 tickets (test-only, disjoint files).
- Wave 2: C2-T03/T05/T06 share `publisher.ex` (one-line edits each;
  recommended merge order T03 → T05 → T06). C2-T03/T05 share two lines of
  `subscription_store.ex`. C2-T04, C2-T07, C3-T01 and C4-T05 touch disjoint
  files.
- C2-T01 must not run alongside U3's event-delivery PR or any other
  `subscription_store.ex` change; C2-T02 must follow U5.
- C2-T09 and C2-T10 are disjoint renames and may run in parallel after T08.
- C5–C7 do not touch C1–C4 files except `aiur.ex` (C6-T02 appends one child)
  and `router.ex` (C7-T01); they can be developed in parallel with C4 once
  their own predecessors land, but ship disabled.

## Cross-feature dependents

MP-E1 (queue topics, optional durable consumer), MP-E2 (`human-needed`
registration), MP-E4 (anchor field, RC-07), MP-E7 (`Delivery` seam,
`listen-mode.changed`), MP-N3 (C7 freshness), MP-N4/N5 (C6 durable consumer,
export feed), MP-N6 (`refs.decision_id` + `instance`), MP-R1 (manifest,
capability, identity).
