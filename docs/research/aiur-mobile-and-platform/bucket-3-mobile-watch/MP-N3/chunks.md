---
feature_id: MP-N3
base_main_sha: 45a290e3
date: 2026-10-06
gate: every ticket is blocked on DESIGN-N3 (owner-design-tasks/DESIGN-N3.md)
---

# MP-N3 — chunks with final ticket IDs

Source: [plan.md](plan.md) §8. Ticket bodies: [tickets/](tickets/README.md).

| Chunk | Outcome | Tickets |
|---|---|---|
| MP-N3-C1 Instance summary provider | `Aiur.InstanceSummary.v1/0` with Fact envelope; never mutates state | C1-T01 envelope, size and redaction guard; C1-T02 agents and pause; C1-T03 Commands awaiting; C1-T04 Executor aggregate; C1-T05 build orders, background agents, capabilities |
| MP-N3-C2 Gateway fan-out | `GET /v1/instances?include=summary`, bounded RPC, 5 s cache | C2-T01 fan-out and mapping; C2-T02 cache |
| MP-N3-C3 MetaRow view model | Pure row model shared with the watch | C3-T01 TS model; C3-T02 shared JSON fixtures |
| MP-N3-C4 App meta-dashboard screen | Native list, navigation, refresh, offline cache | C4-T01 frame and machine states; C4-T02 row; C4-T03 navigation and Executor chat button; C4-T04 refresh; C4-T05 offline cache; C4-T06 device validation |
| MP-N3-C5 Fixture gateway | Synthetic multi-machine server | C5-T01 |

Candidate → final: C1 T1+T6 → C1-T01; C2 T1+T3 → C2-T01, T02 → C2-T02; C3 T1+T2 → C3-T01,
T3 → C3-T02; C4 T2 → C4-T02, T03+T04 → C4-T03, T06 → C4-T05, new C4-T06; C5 T1+T2 → C5-T01.

Order: C1-T01 → (C1-T02..T05 in parallel) → C2-T01 → C2-T02. C3-T02 → C3-T01 → C5-T01 can run
alongside C1/C2. C4 waits for MP-N1 shell tickets, MP-N2 pairing and DESIGN-N3.
