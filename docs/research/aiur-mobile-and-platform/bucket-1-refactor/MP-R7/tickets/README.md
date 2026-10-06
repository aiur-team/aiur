# MP-R7 tickets — harness adapter

Feature plan: [../plan.md](../plan.md). Chunks: [../chunks.md](../chunks.md).
Contract: [../../../contracts/harness-adapter.md](../../../contracts/harness-adapter.md).
Contract requests to the coordinator: [CONTRACT-REQUESTS.md](CONTRACT-REQUESTS.md).

All tickets are wave 1 and researched at base `45a290e3` on 2026-10-06.
Every ticket is blocked on **DESIGN-R7** (Kevin confirms no user-facing
change) and **waits for the U0 review of the prior refactor plan** (RC-19;
plan "U0 review gate"). U0 has no ticket ID, so it is not in `blocked_by`. Status meanings:

- `ready`: fully specified; waits only on DESIGN-R7 and the predecessor tickets listed.
- `blocked`: also waits on an unresolved research question, owner answer or another feature's ticket.

## Ticket table

| ID | Title | Status | blocked_by (besides DESIGN-R7) | Wave |
| --- | --- | --- | --- | --- |
| [MP-R7-C1-T01](MP-R7-C1-T01.md) | Registry-wide harness contract test | ready | — | 1 |
| [MP-R7-C1-T02](MP-R7-C1-T02.md) | Delivery-policy matrix characterization (entry point × harness) | ready | — | 1 |
| [MP-R7-C1-T03](MP-R7-C1-T03.md) | Provider-frame golden tests for operator-message delivery | ready | — | 1 |
| [MP-R7-C1-T04](MP-R7-C1-T04.md) | R7 characterization suite (single-writer lock coverage, one command) | ready | C1-T01, C1-T02, C1-T03 | 1 |
| [MP-R7-C2-T01](MP-R7-C2-T01.md) | Declare per-harness delivery primitives | ready | C1-T01, C1-T03, C1-T04; soft: PR #2870 (RC-22) | 1 |
| [MP-R7-C2-T02](MP-R7-C2-T02.md) | Reserve optional steer and native-question callbacks | ready | C1-T01 | 1 |
| [MP-R7-C2-T03](MP-R7-C2-T03.md) | Running-agent harness delivery read model | ready | C2-T01, C2-T02, C1-T02 | 1 |
| [MP-R7-C3-T01](MP-R7-C3-T01.md) | Move the agent tool surface out of `Aiur.Codex.DynamicTool` into `Aiur.AgentTools` | ready | C1-T01, C1-T03 | 1 |
| [MP-R7-C3-T02](MP-R7-C3-T02.md) | Classify checkpoint-delivery failures through the registry | ready | C1-T01, C1-T04 | 1 |
| [MP-R7-C3-T03](MP-R7-C3-T03.md) | Claude launch telemetry and RC display tailer behind registry keys | ready | C1-T01, C2-T01 | 1 |
| [MP-R7-C3-T04](MP-R7-C3-T04.md) | Route pane interrupts through the optional `interrupt/1` callback | ready | C1-T01, C2-T01 | 1 |
| [MP-R7-C3-T05](MP-R7-C3-T05.md) | Boundary rule in the component checker, with a reasoned allowlist | blocked | C3-T01..T04, MP-R1-C1-T01/T02/T03/T05 | 1 |
| [MP-R7-C3-T06](MP-R7-C3-T06.md) | Backend catalog feeds config validation by registration (Phase D, CR-R1-7) | blocked | C3-T05, MP-R1-C4-T01, MP-R1-C4-T03 | 1 |
| [MP-R7-C4-T01](MP-R7-C4-T01.md) | Harness-declared supervision children | ready | C3-T03 | 1 |
| [MP-R7-C4-T02](MP-R7-C4-T02.md) | Promotion-test record (go/no-go for a physical package) | blocked | C3-T05, C4-T01, MP-R1-C4 harness config ticket, RQ-R7-5 | 1 |
| [MP-R7-C4-T03](MP-R7-C4-T03.md) | Physical `aiur_harness` package skeleton and core move | blocked | C4-T02 = go, CR-R7-1, U8 AGENT_CORE split, MP-R1-C7-T03, MP-R1-C5-T02 | 1 |
| [MP-R7-C4-T04](MP-R7-C4-T04.md) | Move the adapters (Gemini only if #2870 merged) | blocked | C4-T03, U8 CLAUDE/CODEX splits, MP-R1-C5-T02 | 1 |
| [MP-R7-C4-T05](MP-R7-C4-T05.md) | Release packaging check | blocked | C4-T03, C4-T04, CR-R7-1 | 1 |
| [MP-R7-C5-T01](MP-R7-C5-T01.md) | aiur-claude protocol fixture and replay test | ready | C1-T04 | 1 |
| [MP-R7-C5-T02](MP-R7-C5-T02.md) | File the aiur-claude `turn/steer` text-drop defect (cross-repo, issue only) | blocked | DESIGN-R7 §2 decision 2; superseded by MP-E7-C4-T01 if the answer is "leave for E7" | 1 |
| [MP-R7-C6-T01](MP-R7-C6-T01.md) | Contributor documentation: how to add a harness adapter | ready | C2-T01, C2-T02, C3-T05, C4-T01 | 1 |

Totals: 20 tickets, 14 ready, 6 blocked.

## Dependency order

```text
C1-T01 ─┬─► C1-T04 ─┬─► C2-T01 ─┬─► C2-T03
C1-T02 ─┤           │           ├─► C3-T03 ─► C4-T01 ─┐
C1-T03 ─┘           │           └─► C3-T04            │
                    ├─► C3-T02                        │
                    └─► C5-T01                        │
C1-T01 ─► C2-T02 ─► C2-T03                            │
C1-T01 + C1-T03 ─► C3-T01                             │
C3-T01..T04 + MP-R1-C1 checker ─► C3-T05 ─► C4-T02 (go/no-go) ─► C4-T03 ─► C4-T04 ─► C4-T05
C2-T01 + C2-T02 + C3-T05 + C4-T01 ─► C6-T01
C5-T02: independent (owner answer only)
```

## What may run concurrently

- C1-T01, C1-T02 and C1-T03 have no predecessors and touch only new test files.
- After C1: C2-T02, C3-T01, C3-T02 and C5-T01 run in parallel. After C2-T01:
  C3-T03 and C3-T04 run in parallel (different files).
- C4-T03..T05 are conditional. MP-R1 keeps components logical until its
  promotion test passes (MP-R1 migration-plan §5). On current evidence C4-T02
  will record **no-go** (nothing outside aiur consumes the adapters), and
  C4-T03..T05 then close as not needed. C4-T01 ships either way.

## Downstream consumers

- MP-E7-C2/C3 consume C2-T01/T03 (`delivery_primitives`, running backend).
- MP-E7-C4 implements the `steer/3` callback reserved by C2-T02; MP-E7-C5
  uses the tool surface moved by C3-T01.
- MP-E2 native-question capture implements the callbacks reserved by C2-T02.

## Research questions

- RQ-R7-1 resolved: `claude-repl` input typed mid-turn lands inside the same turn (Claude Code docs, accessed 2026-10-06). Foreground capture belongs to MP-E7-C4.
- RQ-R7-2 resolved: allowlist of 33 references in 29 files, in C3-T05.
- RQ-R7-3 resolved: MP-R1 keeps components logical first; C4 re-scoped as a gate plus conditional moves.
- RQ-R7-4 resolved: OpenAI-compat already inserts operator text after each tool result (`open_ai_compat/coding_agent.ex:222-244`).
- RQ-R7-5 (new, open): do MP-R1's promotion criteria hold for harness adapters? Settled by C4-T02.
- Finding R7-C1-F1 (possible live bug): running-entry delivery flags are not recomputed on fallback or RC promotion. Pinned by C1-T02; the fix is MP-E7-C2-T04.
