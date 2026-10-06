# MP-N3 tickets — phone meta-dashboard

Base `45a290e3`, researched 2026-10-06. Every ticket is `blocked` on **DESIGN-N3** (MP-REQ2).
Waves are intra-feature execution order after the gates open; MP-N3 as a whole is delivery
wave 5 ([value-and-sequencing.md](../../../value-and-sequencing.md)).

| ID | Title | Status | Blocked by (beyond DESIGN-N3) | Wave |
|---|---|---|---|---|
| [MP-N3-C1-T01](MP-N3-C1-T01.md) | Summary skeleton, Fact envelope, size and redaction guard | blocked | MP-R1-C2-T02, MP-R1-C3-T01 | 1 |
| [MP-N3-C1-T02](MP-N3-C1-T02.md) | agents.active, capacity, globally_paused | blocked | C1-T01 | 2 |
| [MP-N3-C1-T03](MP-N3-C1-T03.md) | commands.awaiting(_blocking), partial and unavailable | blocked | C1-T01, MP-E2-C7-T1 | 2 |
| [MP-N3-C1-T04](MP-N3-C1-T04.md) | Executor aggregate without recording an observation | blocked | C1-T01, MP-R1-C2-T04 | 2 |
| [MP-N3-C1-T05](MP-N3-C1-T05.md) | build_orders, background_agents, capabilities | blocked | C1-T01, MP-R1-C3-T02, MP-E1-C7 | 2 |
| [MP-N3-C2-T01](MP-N3-C2-T01.md) | Gateway fan-out with timeouts and unsupported mapping | blocked | C1-T01, MP-N2-C4-T01, MP-N2-C4-T04 | 3 |
| [MP-N3-C2-T02](MP-N3-C2-T02.md) | Gateway summary cache (5 s) | blocked | C2-T01 | 4 |
| [MP-N3-C3-T02](MP-N3-C3-T02.md) | Shared meta-row fixtures | blocked | MP-N1-C1-T01 | 1 |
| [MP-N3-C3-T01](MP-N3-C3-T01.md) | MetaRow view model (TS) | blocked | MP-N1-C1-T01, C3-T02 | 2 |
| [MP-N3-C5-T01](MP-N3-C5-T01.md) | Fixture gateway server | blocked | C3-T02 | 3 |
| [MP-N3-C4-T01](MP-N3-C4-T01.md) | Screen frame and machine-level states | blocked | DESIGN-N1, DESIGN-N2, MP-N1-C4-T01, MP-N1-C2-T05, C3-T01, C5-T01 | 5 |
| [MP-N3-C4-T05](MP-N3-C4-T05.md) | Offline cache, encrypted, wiped on revoke | blocked | MP-N1-C2-T01/T02/T05, C3-T01 | 5 |
| [MP-N3-C4-T02](MP-N3-C4-T02.md) | Instance row per DESIGN-N3 | blocked | C4-T01, C3-T01, C2-T01, MP-N1-C3-T01 | 6 |
| [MP-N3-C4-T04](MP-N3-C4-T04.md) | Refresh policy | blocked | C4-T01, C2-T02 | 6 |
| [MP-N3-C4-T03](MP-N3-C4-T03.md) | Open dashboard (WebView) and Executor chat button | blocked | DESIGN-N1, DESIGN-E3, **RQ-TRANSPORT, MP-N2-C10-T01**, MP-N2-C6-T02, MP-N1-C4-T02, MP-N1-C3-T01, C4-T02, MP-E3-C6-T1 | 7 |
| [MP-N3-C4-T06](MP-N3-C4-T06.md) | Device validation (MD-1..MD-7) | blocked | all C4, MP-N2-C10-T05, OQ-N1-4 | 8 |

## Dependency order

```text
C1-T01 ─► C1-T02, C1-T03, C1-T04, C1-T05 ─► C2-T01 ─► C2-T02 ─┐
C3-T02 ─► C3-T01 ─► C5-T01 ───────────────────────────────────┼─► C4-T01 ─► C4-T02, C4-T04 ─► C4-T03 ─► C4-T06
                                     C4-T05 (after C3-T01 + MP-N1-C2) ─┘
```

## What may run concurrently

- C1-T02..T05 in parallel once C1-T01 lands.
- C3-T02 → C3-T01 → C5-T01 in parallel with all of C1 and C2 (they depend only on the contract and the package skeleton).
- C4-T05 in parallel with C4-T02/T04.
- Server tickets (C1, C2) can merge before the app exists; they are inert until the gateway serves `include=summary`.

## Research questions

- RQ-N3-1 resolved (C1-T02): `dashboard_snapshot/2` reads `:persistent_term`, no mailbox.
- RQ-N3-2 resolved (C1-T05): `catalog/1` is an in-process call, upstream reads are async tasks; "disabled" comes from the capability report.
- RQ-N3-3 → dependency on MP-E2-C7-T1 (C1-T03).
- RQ-N3-4 resolved (C4-T04): foreground-only polling; DV-P13 measures.

Contract requests: [CONTRACT-REQUESTS.md](CONTRACT-REQUESTS.md).
