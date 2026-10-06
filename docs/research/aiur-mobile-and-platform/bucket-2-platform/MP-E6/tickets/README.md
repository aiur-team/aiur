# MP-E6 tickets — conversational voice assistant

Base `45a290e3`, researched 2026-10-06. Plan: [../plan.md](../plan.md). Chunks:
[../chunks.md](../chunks.md). Provider research: [../provider-research.md](../provider-research.md).
Contract: [voice-session](../../../contracts/voice-session.md) (draft-2, owned by MP-E6).
Design gate: [DESIGN-E6](../../../owner-design-tasks/DESIGN-E6.md).

**Status rule.** `blocked` = an owner decision, a non-waived design gate, an RQ or the paid
spike is open for that ticket. `ready` = fully specified; only predecessor implementation
tickets remain. DESIGN-E6 waives the backend chunks C2–C4 and C6.

**The paid spike (C1-T01) needs Kevin's explicit E6-OQ9 authorization** with the budget in
the ticket (≤ 60 agent-minutes, ≤ USD 15, hard stop at USD 12 / 50 min).

## Ticket table

| ID | Title | Status | Blocked by (owner / research / spike in bold) | Wave |
| --- | --- | --- | --- | --- |
| [MP-E6-C1-T01](MP-E6-C1-T01.md) | PAID provider validation spike | blocked | **E6-OQ9, DESIGN-E6** | 4 (first, owner-run) |
| [MP-E6-C2-T01](MP-E6-C2-T01.md) | Provider behaviour, events, fake | ready | MP-R5-C1-T01 | 4a |
| [MP-E6-C2-T02](MP-E6-C2-T02.md) | ElevenLabs Agents connection layer | ready | C2-T01 | 4b |
| [MP-E6-C2-T03](MP-E6-C2-T03.md) | Event mapping + tool round trip | blocked | **C1-T01 (spike)**, C2-T02 | 4c |
| [MP-E6-C2-T04](MP-E6-C2-T04.md) | Provider conversation deletion queue | ready | C2-T02, C6-T01 | 4b |
| [MP-E6-C3-T01](MP-E6-C3-T01.md) | `voice.conversation.*` config | blocked | **E6-OQ6, E6-OQ7**, MP-R5-C2-T01 | 4b |
| [MP-E6-C3-T02](MP-E6-C3-T02.md) | `aiur voice setup [--repair]` | blocked | **DESIGN-E6, E6-OQ7, C1-T01 (spike)**, C3-T01, C2-T02 | 4c |
| [MP-E6-C3-T03](MP-E6-C3-T03.md) | Privacy preflight + capability | blocked | **C1-T01 (spike, RQ-E6-3)**, C3-T01, C2-T02, MP-E5-C2-T03 | 4c |
| [MP-E6-C4-T01](MP-E6-C4-T01.md) | Session process and lifecycle | ready | C2-T01, C6-T01, C2-T04, C3-T01, C3-T03 | 4d |
| [MP-E6-C4-T02](MP-E6-C4-T02.md) | Read ports (worker) | ready | C4-T01, MP-E4-C2 (optional) | 4d |
| [MP-E6-C4-T03](MP-E6-C4-T03.md) | ContextBuilder | ready | C4-T02, C6-T01 | 4d |
| [MP-E6-C4-T04](MP-E6-C4-T04.md) | Role registry | blocked | **DESIGN-E6, E6-OQ3**, C3-T01 | 4d |
| [MP-E6-C4-T05](MP-E6-C4-T05.md) | Live context updates from the bus | ready | C4-T01, C4-T03, MP-R2-C5 | 4e |
| [MP-E6-C4-T06](MP-E6-C4-T06.md) | Executor target | ready | C4-T02, C4-T03, MP-E3-C2, MP-E3-C4, MP-E5-C5-T02 | 4e |
| [MP-E6-C5-T01](MP-E6-C5-T01.md) | Read tools | ready | C4-T02, C2-T03 | 4e |
| [MP-E6-C5-T02](MP-E6-C5-T02.md) | Draft store, `propose_instruction` | ready | C5-T01, C6-T01 | 4e |
| [MP-E6-C5-T03](MP-E6-C5-T03.md) | Confirm/discard + delivery via E7 | blocked | **DESIGN-E6, E6-OQ1**, C5-T02, MP-E7-C3, E7 `origin` request | 4f |
| [MP-E6-C5-T04](MP-E6-C5-T04.md) | `consult_agent` | blocked | **DESIGN-E6, E6-OQ2, C1-T01 (spike)**, C5-T02/T03 | 4f |
| [MP-E6-C5-T05](MP-E6-C5-T05.md) | Command-answer drafts | ready | C5-T02, C4-T05, MP-E2 | 4f |
| [MP-E6-C6-T01](MP-E6-C6-T01.md) | Transcript writer | ready | — | 4a |
| [MP-E6-C6-T02](MP-E6-C6-T02.md) | Index + read API | ready | C6-T01 | 4b |
| [MP-E6-C6-T03](MP-E6-C6-T03.md) | `aiur voice transcripts` | ready | C6-T02 | 4c |
| [MP-E6-C6-T04](MP-E6-C6-T04.md) | Transcript deletion | blocked | **DESIGN-E6, E6-OQ5**, C6-T02/T03 | 4f |
| [MP-E6-C7-T01](MP-E6-C7-T01.md) | `voice:converse` channel | blocked | **DESIGN-E6**, C4-T01, C2-T03, MP-E5-C2-T01 | 4f |
| [MP-E6-C7-T02](MP-E6-C7-T02.md) | Converse panel and states | blocked | **DESIGN-E6, E6-OQ4, E6-OQ8**, C7-T01, MP-E5-C1-T02, MP-E5-C3-T02 | 4g |
| [MP-E6-C7-T03](MP-E6-C7-T03.md) | Draft cards | blocked | **DESIGN-E6, E6-OQ1**, C7-T02, C5-T03, C5-T05 | 4g |
| [MP-E6-C7-T04](MP-E6-C7-T04.md) | Playback and barge-in | blocked | **DESIGN-E6, C1-T01 (spike, RQ-E6-5)**, C7-T02 | 4g |
| [MP-E6-C8-T01](MP-E6-C8-T01.md) | History views | blocked | **DESIGN-E6**, C6-T02, C7-T02 | 4h |
| [MP-E6-C8-T02](MP-E6-C8-T02.md) | Continue with carried drafts | blocked | **DESIGN-E6**, C8-T01, C4-T03, C5-T02 | 4h |
| [MP-E6-C8-T03](MP-E6-C8-T03.md) | Link delivered drafts to E4 anchors | blocked | **DESIGN-E6, DESIGN-E4**, C8-T01, MP-E4-C3, MP-E7-C3 | 4h |
| [MP-E6-C9-T01](MP-E6-C9-T01.md) | Docs + end-to-end verification | blocked | **DESIGN-E6, E6-OQ7**, user-visible E6 tickets | 4i |

Totals: 31 tickets — 14 ready, 17 blocked.

## Dependency order

```text
C6-T01 ─► C6-T02 ─► C6-T03 ; C6-T04 (E6-OQ5)
MP-R5-C1 ─► C2-T01 ─► C2-T02 ─┬─► C2-T04 (+C6-T01)
                               └─► C2-T03 ◄── C1-T01 (PAID spike, E6-OQ9)
MP-R5-C2 ─► C3-T01 (E6-OQ6/7) ─► C3-T02 (spike) ; C3-T03 (spike)
C2-T01 + C6-T01 + C2-T04 + C3-T01 + C3-T03 ─► C4-T01 ─► C4-T02 ─► C4-T03 ─► C4-T05 ; C4-T06
                                                       C4-T04 (E6-OQ3)
C4-T02 + C2-T03 ─► C5-T01 ─► C5-T02 ─┬─► C5-T03 (E6-OQ1, MP-E7-C3) ─► C5-T04 (E6-OQ2)
                                      └─► C5-T05 (MP-E2)
C4-T01 + MP-E5-C2-T01 ─► C7-T01 ─► C7-T02 ─► C7-T03 ; C7-T04
C7-T02 + C6-T02 ─► C8-T01 ─► C8-T02 ; C8-T03
everything user-visible ─► C9-T01
```

## Concurrency

- Can start first (after MP-R5-C1): C6-T01, C2-T01; then C2-T02, C6-T02, C2-T04 in parallel.
- The spike (C1-T01) runs in parallel with all backend work; it only gates C2-T03, C3-T02,
  C3-T03, C5-T04 and C7-T04.
- C4-T05, C4-T06, C5-T01 can run in parallel after C4-T03.
- UI tickets (C7, C8) wait for DESIGN-E6 and run in the listed order.

## New research questions

None open beyond RQ-E6-1..6 (assigned to the spike). RQ-E6-7 (frame budget) is resolved in
voice-session §3.6; RQ-E6-8 (E4 tail/since read) is resolved by the conversations contract
§7 (`list_entries` with `tail` / `after` and the required `principal:` option; voice
context reads use `:internal`, device-rendered text uses `{:device, device_id}`).

Contract requests: [CONTRACT-REQUESTS.md](CONTRACT-REQUESTS.md).
