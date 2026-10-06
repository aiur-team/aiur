# MP-E3 tickets — first-class Executor communication

Base `45a290e3`, researched 2026-10-06. Owner gate:
[DESIGN-E3](../../../owner-design-tasks/DESIGN-E3.md). Contracts consumed:
conversations-transcripts-anchors (MP-E4), listener-mode (MP-E7),
harness-adapter (MP-R7, "attached" profile §6.8), command-request-resolution
(MP-E2), identity (MP-R1). Every implementation ticket is blocked on DESIGN-E3.
Only the Codex research spike C3-T01 is ready now.

Binding reconciliation applied: RC-05 (C5 write ticket after MP-E7-C3; read
chunks are not blocked). C5-T01 ships in wave 3 with the composer disabled
until MP-E7-C6 (Executor hook delivery, wave 4) is installed — this answers
MP-E7 CR-E7-2. Ticket IDs are two-digit (CR-E7-5).

## Tickets

| ID | Title | Status | Blocked by | Wave / step |
| --- | --- | --- | --- | --- |
| MP-E3-C1-T01 | Session binding store (one attached session, takeover, TTL) | blocked | DESIGN-E3, MP-E4-C1-T02 | 3 / s1 |
| MP-E3-C1-T02 | Hook ingest: token, bearer plug, endpoint, normalizer | blocked | DESIGN-E3, C1-T01 | 3 / s2 |
| MP-E3-C1-T03 | CLI `executor-attach` / `-detach` / `-session` | blocked | DESIGN-E3, C1-T01, C1-T02 | 3 / s3 |
| MP-E3-C1-T04 | Hook config generator/installer | blocked | DESIGN-E3, C1-T02 | 3 / s3 |
| MP-E3-C2-T01 | Claude transcript ingest into the Executor conversation | blocked | DESIGN-E3, C1-T02, MP-E4-C1-T02 | 3 / s3 |
| MP-E3-C2-T02 | Claude format drift guard | blocked | DESIGN-E3, C2-T01 | 3 / s4 |
| MP-E3-C3-T01 | Spike: Codex TUI rollout fixtures, hook path, subagent fields | **ready** | — | any / s0 |
| MP-E3-C3-T02 | Codex rollout reader | blocked | DESIGN-E3, C3-T01, C2-T01 | 3 / s4 |
| MP-E3-C3-T03 | Executor read capability record | blocked | DESIGN-E3, C2-T02, C3-T02 | 3 / s5 |
| MP-E3-C4-T01 | Harness-state machine (TTL → unknown) | blocked | DESIGN-E3, C1-T02, RQ-E3-5 | 3 / s3 |
| MP-E3-C4-T02 | Background agents (unsupported ≠ 0) | blocked | DESIGN-E3, C1-T02, C3-T01 | 3 / s3 |
| MP-E3-C4-T03 | Blockers with per-source availability | blocked | DESIGN-E3, MP-E2-C1-T01, MP-E2-C6-T01, MP-E2-C6-T03 | 3 / s3 |
| MP-E3-C4-T04 | (Optional) aiur-run emits `executor.progress` | blocked | DESIGN-E3, OQ-E3-6, MP-E4-C3-T02 | 3 / s5 |
| MP-E3-C4-T05 | `Executor.Status.snapshot/0` + CLI/JSON | blocked | DESIGN-E3, C4-T01, C4-T02, C4-T03, C3-T03 | 3 / s6 |
| MP-E3-C5-T01 | Executor send adapter over `Aiur.Listener.send/3` | blocked | DESIGN-E3, DESIGN-E7, MP-E7-C3-T03, MP-E7-C3-T04, MP-E4-C6-T01, C1-T01 | 3 (after E7-C3) / s5 |
| MP-E3-C6-T01 | `/executor` view and Executor states | blocked | DESIGN-E3, DESIGN-E4, MP-E4-C5-T01, MP-E4-C5-T02, C2-T01 | 3 / s5 |
| MP-E3-C6-T02 | Status header | blocked | DESIGN-E3, C6-T01, C4-T05 | 3 / s7 |
| MP-E3-C6-T03 | Blockers and background-agents panels | blocked | DESIGN-E3, DESIGN-E2, C6-T01, C4-T02, C4-T03, MP-E4-C6-T02 | 3 / s7 |
| MP-E3-C7-T01 | `executor-attach --check` | blocked | DESIGN-E3, C1-T03, C1-T04, C2-T02 | 3 / s5 |
| MP-E3-C7-T02 | Docs and skills | blocked | DESIGN-E3, C1-T03, MP-E4-C8-T02 | 3 / s4 |

Counts per chunk: C1 4 · C2 2 · C3 3 · C4 5 · C5 1 · C6 3 · C7 2 = 20
(1 ready, 19 blocked).

## Dependency order

```text
MP-E4-C1-T02 ─► C1-T01 ─► C1-T02 ─┬─► C1-T03 ─┬─► C7-T01 (+ C1-T04, C2-T02)
                                  │           └─► C7-T02 (+ MP-E4-C8-T02)
                                  ├─► C1-T04
                                  ├─► C2-T01 ─► C2-T02 ─┐
                                  ├─► C4-T01 (RQ-E3-5)  │
                                  └─► C4-T02 ◄─ C3-T01  │
C3-T01 (spike) ─► C3-T02 (+ C2-T01) ─► C3-T03 ◄─────────┘
MP-E2-C6-T01/T03 ─► C4-T03
C4-T01, C4-T02, C4-T03, C3-T03 ─► C4-T05 ─► C6-T02
MP-E4-C5-T01/T02 + C2-T01 ─► C6-T01 ─► C6-T02, C6-T03 (+ MP-E4-C6-T02)
MP-E7-C3-T03/T04 + MP-E4-C6-T01 + C1-T01 ─► C5-T01      (live delivery needs MP-E7-C6)
C1-T01, C1-T02 ─► MP-E7-C6-T01 (Executor hook delivery, wave 4)
```

## What may run concurrently

- C3-T01 now.
- After C1-T02: C1-T03, C1-T04, C2-T01, C4-T01 and C4-T02 in parallel; C4-T03
  whenever MP-E2-C6 lands.
- After C2-T01: C2-T02 and C3-T02 in parallel; C6-T01 once MP-E4-C5-T02 exists.
- C5-T01 after MP-E7-C3; it can run in parallel with C6-T01.

## Research questions

- RQ-E3-1 — mostly answered by census (rollout `event_msg/item_completed` item
  types at 0.157–0.160.1); C3-T01 closes the codex-tui 0.160 gap.
- RQ-E3-2 — optional in C3-T01; the rollout reader is the default; not blocking.
- RQ-E3-3 — measured in C2-T01 (manual flush-lag check).
- RQ-E3-4 — out of scope; subagent transcripts are not shown (C4-T02).
- RQ-E3-5 — resolved inside C4-T01 step 0 (blocks that ticket only).
- RQ-E3-6 — answered by C3-T01 (Codex subagent fields).

Contract requests: [CONTRACT-REQUESTS.md](CONTRACT-REQUESTS.md).
