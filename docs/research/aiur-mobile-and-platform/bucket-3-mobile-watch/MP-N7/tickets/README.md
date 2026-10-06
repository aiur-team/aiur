---
feature_id: MP-N7
base_sha: 45a290e3
researched: 2026-10-06
gate: every ticket is blocked on DESIGN-N7 (owner-design-tasks/DESIGN-N7.md)
---

# MP-N7 tickets (watch apps)

25 tickets, all `blocked` (DESIGN-N7 is open; cross-feature predecessors are unbuilt).
Waves are intra-feature order after the gates open; MP-N7 as a whole is delivery wave 5
(after MP-N1 and MP-N6, `value-and-sequencing.md`).

| ID | Title | Status | Blocked by (beyond DESIGN-N7) | Wave |
|---|---|---|---|---|
| [MP-N7-C1-T01](MP-N7-C1-T01.md) | Watch-link v1 schemas, fixtures, decode check | blocked | MP-N1-C1-T01, MP-N1-C2-T04 | 1 |
| [MP-N7-C1-T02](MP-N7-C1-T02.md) | iOS watch broker (WatchConnectivity) | blocked | RQ-TRANSPORT, MP-N2-C10-T01, C1-T01, MP-N1-C2-T01/T05, MP-N1-C3-T04, MP-N6-C1-T01/T03 | 2 |
| [MP-N7-C1-T03](MP-N7-C1-T03.md) | Android watch broker (Data Layer) | blocked | same as C1-T02 with MP-N1-C2-T02 | 2 |
| [MP-N7-C1-T04](MP-N7-C1-T04.md) | Late-answer guard | blocked | DESIGN-N6, C1-T01, MP-N6-C1-T01 | 2 |
| [MP-N7-C1-T05](MP-N7-C1-T05.md) | Snapshot push triggers and debounce | blocked | RQ-TRANSPORT, C1-T02/T03, MP-N1-C3-T01/T04, MP-N3-C3-T01 | 3 |
| [MP-N7-C2-T01](MP-N7-C2-T01.md) | watchOS target, PhoneLink | blocked | MP-N1-C1-T01/T02/T03, MP-N1-C2-T01, C1-T01, N1-RQ3 | 2 |
| [MP-N7-C2-T02](MP-N7-C2-T02.md) | watchOS instance list and detail | blocked | DESIGN-N3, C2-T01, C1-T05, MP-N3-C3-T01/T02 | 4 |
| [MP-N7-C2-T03](MP-N7-C2-T03.md) | watchOS Command card | blocked | DESIGN-N6, DESIGN-E2, C2-T02, C1-T02, C1-T04 | 5 |
| [MP-N7-C2-T04](MP-N7-C2-T04.md) | Apple Watch notification routing | blocked | DESIGN-N4, C2-T03, MP-N1-C6-T01, MP-N4-C6-T01 | 6 |
| [MP-N7-C2-T05](MP-N7-C2-T05.md) | watchOS control inventory test | blocked | C2-T02, C2-T03 | 6 |
| [MP-N7-C2-T06](MP-N7-C2-T06.md) | Option buttons in the watch long-look (conditional) | blocked | DESIGN-N6, C2-T04, C6-T01 (DV-W1, DV-W10) | 9 |
| [MP-N7-C3-T01](MP-N7-C3-T01.md) | Wear OS project, PhoneLink, CI | blocked | MP-N1-C1-T01/T02, MP-N1-C2-T02, C1-T01 | 2 |
| [MP-N7-C3-T02](MP-N7-C3-T02.md) | Wear OS instance list and detail | blocked | DESIGN-N3, C3-T01, C1-T05, MP-N3-C3-T01/T02 | 4 |
| [MP-N7-C3-T03](MP-N7-C3-T03.md) | Wear OS Command card | blocked | DESIGN-N6, DESIGN-E2, C3-T02, C1-T03, C1-T04 | 5 |
| [MP-N7-C3-T04](MP-N7-C3-T04.md) | Wear-local Command notifications, bridging excluded | blocked | DESIGN-N4, C3-T03, C1-T03, MP-N4-C5-T02, MP-N4-C6-T02 | 6 |
| [MP-N7-C3-T05](MP-N7-C3-T05.md) | Wear OS control inventory test | blocked | C3-T02, C3-T03 | 6 |
| [MP-N7-C4-T01](MP-N7-C4-T01.md) | Mic choice sheet (D16) on both watches | blocked | DESIGN-E5/E6/N6, C2-T03, C3-T03, C2-T05, C3-T05 | 7 |
| [MP-N7-C4-T02](MP-N7-C4-T02.md) | System-recognizer Dictate + disclosure | blocked | DESIGN-E5/N6, OQ-N7-2, C4-T01 | 8 |
| [MP-N7-C4-T03](MP-N7-C4-T03.md) | Watch audio capture and transfer | blocked | DESIGN-E5/E6, C4-T01, C1-T01 | 8 |
| [MP-N7-C4-T04](MP-N7-C4-T04.md) | Phone relay to device voice path | blocked | DESIGN-E5, RQ-TRANSPORT, MP-N2-C10-T01, RC-16 E5 path, C4-T03, C1-T02/T03, RQ-N7-6 | 9 |
| [MP-N7-C4-T05](MP-N7-C4-T05.md) | Turn-based Converse | blocked | DESIGN-E6, OQ-N7-3, C4-T04, MP-E6-C4-T01, MP-E6-C5-T03, RC-16, RQ-N7-6 | 10 |
| [MP-N7-C5-T01](MP-N7-C5-T01.md) | watchOS complication (conditional) | blocked | OQ-N7-4, C2-T02, C1-T05 | 5 |
| [MP-N7-C5-T02](MP-N7-C5-T02.md) | Wear OS Tile (conditional) | blocked | OQ-N7-4, C3-T02, C5-T01 | 6 |
| [MP-N7-C6-T01](MP-N7-C6-T01.md) | Apple Watch device validation | blocked | OQ-N1-4, C2-T03/T04, C4-T02/T05, MP-N1-C6-T01, MP-N4-C6-T01, MP-N2-C10-T01 | 11 |
| [MP-N7-C6-T02](MP-N7-C6-T02.md) | Wear OS device validation | blocked | OQ-N1-4, C3-T03/T04, C4-T02/T05, MP-N4-C5-T02, MP-N4-C6-T02, MP-N2-C10-T01 | 11 |

## Dependency order

```text
C1-T01 ─┬─► C1-T02 ─┐            ┌─► C2-T02 ─► C2-T03 ─┬─► C2-T04 ─► (C6-T01 DV-W10) ─► C2-T06
        ├─► C1-T03 ─┼─► C1-T05 ──┤                     └─► C2-T05
        ├─► C1-T04 ─┘            └─► C3-T02 ─► C3-T03 ─┬─► C3-T04
        ├─► C2-T01 ───────────────────▲                └─► C3-T05
        └─► C3-T01 ───────────────────┘
C2-T03 + C3-T03 + C2-T05 + C3-T05 ─► C4-T01 ─┬─► C4-T02
                                             └─► C4-T03 ─► C4-T04 ─► C4-T05
C2-T02 ─► C5-T01 ─► C5-T02 (both conditional on OQ-N7-4)
everything above ─► C6-T01 (Apple) / C6-T02 (Wear)
```

## Concurrency

- Wave 2: C1-T02, C1-T03, C1-T04, C2-T01, C3-T01 can run in parallel (separate files; the two
  brokers share only fixtures).
- Apple (C2-*) and Wear (C3-*) tracks run in parallel throughout; tickets that switch a
  fixture to shared (C3-T02, C3-T03, C3-T05, C5-T02) touch the other platform's test path,
  so each must land after its Apple twin.
- C4-T02 and C4-T03 can run in parallel. C5 can run any time after its list ticket.
- If DESIGN-N7 D-N7-6 chooses "Apple Watch first", all C3-* and C6-T02 move after C6-T01.

## Chunk mapping changes (vs chunks.md candidates)

- N7-C3-T4 (CI) merged into MP-N7-C3-T01; N7-C4-T6 (disclosure) merged into MP-N7-C4-T02.
- New: MP-N7-C2-T06 (dynamic long-look actions, from N7-RQ1), MP-N7-C6 (device validation).
- Notification routing on Wear (C3-T04) changed design per N7-RQ2 (Wear-local notifications).
