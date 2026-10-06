# MP-E5 tickets — dashboard voice input

Base `45a290e3`, researched 2026-10-06. Plan: [../plan.md](../plan.md). Chunks:
[../chunks.md](../chunks.md). Contract: [voice-session](../../../contracts/voice-session.md)
(draft-2). Design gate: [DESIGN-E5](../../../owner-design-tasks/DESIGN-E5.md).

**Status rule.** `blocked` = an owner decision, a non-waived design gate, an RQ or a spike is
open for that ticket. `ready` = fully specified; only predecessor implementation tickets
(listed in `blocked_by`) remain. DESIGN-E5 waives C1, C2 and C8 (no dashboard-visible change);
those tickets still list it for traceability.

## Ticket table

| ID | Title | Status | Blocked by (owner / research items in bold) | Wave |
| --- | --- | --- | --- | --- |
| [MP-E5-C1-T01](MP-E5-C1-T01.md) | Extract `<.voice_input>` component | ready | MP-R5-C1-T02 | 4a |
| [MP-E5-C1-T02](MP-E5-C1-T02.md) | Split the browser voice controller | ready | MP-R5-C1-T02 | 4a |
| [MP-E5-C1-T03](MP-E5-C1-T03.md) | Standalone `VoiceInput` hook (RQ-E5-1, RQ-E5-3) | ready | C1-T01, C1-T02 | 4b |
| [MP-E5-C2-T01](MP-E5-C2-T01.md) | `voice:dictate` v1 join + `reason_code` | ready | MP-R5-C1-T02 | 4a |
| [MP-E5-C2-T02](MP-E5-C2-T02.md) | Channel `cancel` | ready | C2-T01 | 4b |
| [MP-E5-C2-T03](MP-E5-C2-T03.md) | `voice.stt`/`voice.tts` capabilities at render | ready | MP-R5-C1-T01, MP-R1-C2 | 4a |
| [MP-E5-C3-T01](MP-E5-C3-T01.md) | D16 Dictate/Converse choice | blocked | **DESIGN-E5, E5-OQ1, E5-OQ6**, C1-T01/T02, C2-T01/T03 | 4c |
| [MP-E5-C3-T02](MP-E5-C3-T02.md) | Converse hand-off to the E6 panel | blocked | **DESIGN-E5, DESIGN-E6**, C3-T01 (MP-E6-C7-T02 consumes it; RC-28) | 4e |
| [MP-E5-C3-T03](MP-E5-C3-T03.md) | Legacy auto-submit voice chat | blocked | **DESIGN-E5, E5-OQ2**, C3-T01 | 4c |
| [MP-E5-C4-T01](MP-E5-C4-T01.md) | Dictated Command answers | blocked | **DESIGN-E5, E5-OQ3, DESIGN-E2**, C1-T03, C3-T01, C2-T01 | 4d |
| [MP-E5-C4-T02](MP-E5-C4-T02.md) | Dictated Command revisions | blocked | **DESIGN-E5, E5-OQ3, DESIGN-E2**, C4-T01 | 4d |
| [MP-E5-C5-T01](MP-E5-C5-T01.md) | Agent log modal voice | blocked | **DESIGN-E5**, C1-T03, C3-T01 | 4d |
| [MP-E5-C5-T02](MP-E5-C5-T02.md) | Executor composer voice | blocked | **DESIGN-E5, DESIGN-E3**, MP-E3-C5-T01, MP-E3-C6, C1-T03, C3-T01, C2-T01 | 4d |
| [MP-E5-C6-T01](MP-E5-C6-T01.md) | States, copy, unavailable presentation | blocked | **DESIGN-E5, E5-OQ4**, C3-T01, C2-T01, C2-T03 | 4d |
| [MP-E5-C6-T02](MP-E5-C6-T02.md) | Cancel control and Escape | blocked | **DESIGN-E5, E5-OQ5**, C6-T01, C2-T02 | 4e |
| [MP-E5-C6-T03](MP-E5-C6-T03.md) | Delivery state from the send path | blocked | **DESIGN-E5**, C6-T01, MP-E7-C3-T04, MP-E4-C6, MP-E2 | 4e |
| [MP-E5-C7-T01](MP-E5-C7-T01.md) | End-to-end verification and docs audit | blocked | **DESIGN-E5**, all user-visible E5 tickets, C8-T02 | 5 (after C8-T02) |
| [MP-E5-C8-T01](MP-E5-C8-T01.md) | Device voice ticket + `/voice/device` socket (RC-16) | ready | C2-T01, MP-N2-C1-T03, MP-N2-C6-T01 | 5 (with N2) |
| [MP-E5-C8-T02](MP-E5-C8-T02.md) | End device sessions on revocation | ready | C8-T01, MP-N2-C7-T01 | 5 (with N2) |

Totals: 19 tickets — 8 ready, 11 blocked (all 11 on DESIGN-E5 plus named owner questions).

## Dependency order

```text
MP-R5-C1 ─┬─► C1-T01 ─┐
          ├─► C1-T02 ─┴─► C1-T03 ─┐
          ├─► C2-T01 ─► C2-T02    │
          └─► C2-T03 (+MP-R1-C2)  │
DESIGN-E5 ─► C3-T01 ◄─────────────┘ (and C2-T01, C2-T03)
             ├─► C3-T03
             ├─► C4-T01 ─► C4-T02         (DESIGN-E2)
             ├─► C5-T01
             ├─► C5-T02                   (MP-E3-C5/C6)
             ├─► C6-T01 ─► C6-T02 ; C6-T03 (MP-E7-C3, MP-E4-C6)
             └─► C3-T02 ─► MP-E6-C7-T02   (RC-28)
all user-visible ─► C7-T01
C2-T01 + MP-N2-C1/C6 ─► C8-T01 ─► C8-T02 (MP-N2-C7) ─► consumed by MP-N6/N7
```

## Concurrency

- Wave 4a (after MP-R5-C1): C1-T01, C1-T02, C2-T01, C2-T03 in parallel (disjoint files).
- 4b: C1-T03 and C2-T02 in parallel.
- After DESIGN-E5 and C3-T01: C3-T03, C4-T01, C5-T01, C5-T02, C6-T01 in parallel (C4-T01 and
  C6-T01 both touch the controller — merge C6-T01 first or rebase; they touch different
  functions).
- C8 runs in **wave 5** alongside MP-N2 (RC-29), after MP-N2-C6; it is independent of the
  dashboard tickets after C2-T01. Dashboard Converse (MP-E6-C7) does not wait for it (RC-30).

## Test-command note

Elixir tests: `env -C src mise exec -- mix test <path>`, run in an implementation worktree
with `GITHUB_TOKEN`/`GH_TOKEN` unset and `~/.aiur/github-budget/agent-token` hash-checked
before and after (a local `mix test` boots aiur and can overwrite it). Browser:
`env -C src/browser npm run test:units`. Lint: `make -C src fmt-check lint`.

Contract requests: [CONTRACT-REQUESTS.md](CONTRACT-REQUESTS.md).
