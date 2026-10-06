# MP-N5 tickets — notification preferences and progress updates

Base `45a290e3`, researched 2026-10-06. Plan: [../plan.md](../plan.md); chunks:
[../chunks.md](../chunks.md). Gate: [DESIGN-N5](../../../owner-design-tasks/DESIGN-N5.md).
Status semantics as in [MP-N4 tickets/README.md](../../MP-N4/tickets/README.md): `ready` =
spec complete (still waits for `blocked_by`); `blocked` = an open owner/design/research item
changes what is built. DESIGN-N5 releases the store/API (C1), the policy (C2) and the
noise logic (C3) before approval, written `DESIGN-N5 (no-UI release)`.

## Tickets

| ID | Title | Status | Blocked by (beyond DESIGN-N5) | Wave |
| --- | --- | --- | --- | --- |
| [MP-N5-C2-T00](MP-N5-C2-T00.md) | Post-refactor path refresh | ready | MP-N4-C3-T00, MP-R2-C5/C6, MP-E1-C7, MP-E2-C1-T3 | 0 |
| [MP-N5-C1-T01](MP-N5-C1-T01.md) | Preference schema v1 + machine-store file | ready | MP-N4-C3-T00, MP-N2-C1-T1/T2 | 1 |
| [MP-N5-C1-T02](MP-N5-C1-T02.md) | Effective preferences + capability masking | ready | C1-T01, MP-N4-C3-T04 | 2 |
| [MP-N5-C2-T01](MP-N5-C2-T01.md) | Policy process, Source adapter, ledger, reconciliation | ready | C2-T00, MP-N4-C3-T02, MP-R2-C6-T04 | 2 |
| [MP-N5-C1-T03](MP-N5-C1-T03.md) | Settings API (gateway GET/PATCH; instance options) | ready | C1-T02, MP-N2-C4-T4, MP-N2-C6-T1, RQ-TRANSPORT | 3 |
| [MP-N5-C2-T02](MP-N5-C2-T02.md) | Command rules | ready | C2-T01, C1-T02, MP-E2-C1-T3, MP-E2-C2-T2, DESIGN-E2 §6.2 | 3 |
| [MP-N5-C2-T03](MP-N5-C2-T03.md) | Progress rules (per-device 10/25/50 %, RC-10) | ready | C2-T01, C1-T02, MP-E1-C7 | 3 |
| [MP-N5-C2-T04](MP-N5-C2-T04.md) | Opt-in rules | ready | C2-T01, C1-T02 | 3 |
| [MP-N5-C1-T04](MP-N5-C1-T04.md) | Seed at pairing + silent progress baseline | ready | C1-T01, C2-T03, MP-N2-C5-T2 | 4 |
| [MP-N5-C3-T01](MP-N5-C3-T01.md) | Coalescing + digest | ready | C2-T02..T04 | 4 |
| [MP-N5-C3-T02](MP-N5-C3-T02.md) | Hourly cap | ready | C3-T01 | 5 |
| [MP-N5-C3-T03](MP-N5-C3-T03.md) | Send-time staleness hook | ready | MP-N4-C3-T02, C3-T01 | 5 |
| [MP-N5-C1-T05](MP-N5-C1-T05.md) | Per-instance blocker mute | **blocked** | **DESIGN-N5 D-1 (OQ-N5-1)**, DESIGN-N3, C1-T02, C2-T02 | 6 |
| [MP-N5-C4-T01](MP-N5-C4-T01.md) | Phone settings screens | **blocked** | **DESIGN-N5 §2/D-7/D-8**, DESIGN-N1, DESIGN-N3, C1-T03, N1-C4-T1, N1-C3-T2, RQ-TRANSPORT | 6 |
| [MP-N5-C4-T02](MP-N5-C4-T02.md) | OS permission state | **blocked** | **DESIGN-N5/N4 copy**, C4-T01, MP-N4-C4-T05/C5-T05 | 7 |
| [MP-N5-C4-T03](MP-N5-C4-T03.md) | Offline/stale/conflict/unpaired states | **blocked** | **DESIGN-N5 §4**, C4-T01, N1-C5-T1, RQ-TRANSPORT | 7 |
| [MP-N5-C5-T01](MP-N5-C5-T01.md) | Notifications guide page | **blocked** | **DESIGN-N5 answers**, DESIGN-N4, C4-T01, MP-N4-C2-T05 | 8 |

Totals: 17 tickets — C1 5, C2 5, C3 3, C4 3, C5 1. **Ready 12, blocked 5.**

Owner values that are **constants** (spec unchanged by the answer, value set at approval):
D-4 non-blocking Commands default (`on` proposed), D-5 re-notify a reopened root
(`true`), D-8 queue milestones share the build-order setting (`true`; "own toggle" would be
an additive field + a C4 row). D-2 reminders, D-3 push/comment events and D-6 quiet hours
are proposals of "nothing built"; a "yes" adds a new ticket.

## Order

```text
C2-T00 ─► C2-T01 ─► {C2-T02, C2-T03, C2-T04} ─► C3-T01 ─► {C3-T02, C3-T03}
C1-T01 ─► C1-T02 ─► C1-T03 ─► C4-T01 ─► {C4-T02, C4-T03} ─► C5-T01
C2-T03 ─► C1-T04 ;  C2-T02 ─► C1-T05 (if D-1 = yes)
```

## May run concurrently

C1-T01/T02 ∥ C2-T00/T01; the three rule tickets C2-T02/T03/T04 in parallel; C3-T02 ∥
C3-T03; C4-T02 ∥ C4-T03. The whole C1–C3 track runs in parallel with MP-N4 C4/C5 (native).

## Changes to plan/chunks made in Phase C

- C2 renumbered: T01 is now the Source/ledger/reconciliation foundation; rules are T02
  (Commands), T03 (progress), T04 (opt-ins).
- RC-10: progress via `Aiur.BuildQueue.progress/1` + progress-changed signal; the Phase B
  60 s `CatalogStore` fallback is **dropped** (E1-C7 is a hard predecessor; one progress
  computation keeps dashboard and notifications in agreement). RQ-N5-1 resolved.
- RC-09: Source adapter uses the export feed's DurableConsumer when enabled, else a live
  `Exchange` subscription; reconciliation guarantees correctness in both.
- RC-03: preferences live in the machine store (`notification-preferences.json`), not in
  any `config` file. Overrides keyed by `instance_id` (RC-02).
- New C1-T05 isolates the D-1 mute so the rest of C1 is not blocked.

Contract requests: [CONTRACT-REQUESTS.md](CONTRACT-REQUESTS.md).
