# MP-E4 tickets — dashboard conversations and event navigation

Base `45a290e3`, researched 2026-10-06. Contract owned:
[`contracts/conversations-transcripts-anchors.md`](../../../contracts/conversations-transcripts-anchors.md)
(Phase C changes in its §15). Owner gate: [DESIGN-E4](../../../owner-design-tasks/DESIGN-E4.md).
Every implementation ticket is blocked on DESIGN-E4. Only the measurement ticket
C1-T00 is ready now.

Binding reconciliation applied: RC-02 (instance id not in `conversation_id`),
RC-05 (C6 write tickets after MP-E7-C3; read chunks are not blocked), RC-06
(MP-R6-C1-T01 extracts `Aiur.Conversation.Anchors`; C3-T01 extends it; C7 is one
data-source ticket), RC-07 (journal `pos` is the only entry address).

## Tickets

Wave = delivery wave (value-and-sequencing.md); step = intra-feature order.

| ID | Title | Status | Blocked by | Wave / step |
| --- | --- | --- | --- | --- |
| MP-E4-C1-T00 | RQ-E4-1: journal size census on the live fleet (read-only) | ready | — | any / s0 |
| MP-E4-C1-T01 | Identity, entry/session records, append-only store | blocked | DESIGN-E4, C1-T00 | 3 / s1 |
| MP-E4-C1-T02 | Journal writer: positions, sessions, dedup, gaps, broadcast | blocked | DESIGN-E4, C1-T01 | 3 / s2 |
| MP-E4-C1-T03 | Worker tee from the three daemon ingest points | blocked | DESIGN-E4, C1-T02 | 3 / s3 |
| MP-E4-C2-T01 | `Conversation.History`: paging, sessions, subscribe | blocked | DESIGN-E4, C1-T02 | 3 / s3 |
| MP-E4-C2-T02 | Read-only JSON routes + `resolve` | blocked | DESIGN-E4, C2-T01 | 3 / s4 |
| MP-E4-C3-T01 | Extend `Conversation.Anchors`: positions + precision ladder | blocked | DESIGN-E4, MP-R6-C1-T01, C1-T01 | 3 / s2 |
| MP-E4-C3-T02 | Anchor resolver (live bus, exact + observed, anchors.jsonl) | blocked | DESIGN-E4, C3-T01, C1-T03, C2-T01 | 3 / s4 |
| MP-E4-C3-T03 | Causal anchors: git push, gh pr create/merge | blocked | DESIGN-E4, C3-T02 | 3 / s5 |
| MP-E4-C4-T01 | Jump-point catalogue | blocked | DESIGN-E4, C3-T02 | 3 / s5 |
| MP-E4-C4-T02 | Command ↔ conversation links | blocked | DESIGN-E4, DESIGN-E2, C3-T02, C5-T01 | 3 / s5 |
| MP-E4-C5-T01 | `ConversationLive`: route, states, paging, live tail | blocked | DESIGN-E4, C2-T01 | 3 / s4 |
| MP-E4-C5-T02 | Entry rendering | blocked | DESIGN-E4, C5-T01 | 3 / s5 |
| MP-E4-C5-T03 | Event navigation and jump | blocked | DESIGN-E4, C5-T02, C4-T01, C3-T02 | 3 / s6 |
| MP-E4-C5-T04 | Link-in, phone width, GUI guide | blocked | DESIGN-E4, C5-T03 | 3 / s7 |
| MP-E4-C6-T01 | Composer via `Aiur.Listener.send/3` + delivery overlay | blocked | DESIGN-E4, DESIGN-E7, MP-E7-C3-T03, MP-E7-C3-T04, C5-T01 | 3 (after E7-C3) / s5 |
| MP-E4-C6-T02 | Inline answers to this agent's open Commands | blocked | DESIGN-E4, DESIGN-E2, MP-E2-C1-T01, MP-E2-C3-T01, C4-T02 | 3 / s6 (no E7-C3 dependency; CR-E4-4) |
| MP-E4-C7-T01 | Stream Deck logs read the journal | blocked | DESIGN-E4, DESIGN-R6, MP-R6-C1-T01, C2-T01, C1-T03 | 3 / s4 |
| MP-E4-C8-T01 | Pre-journal importer | blocked | DESIGN-E4, C1-T03 | 3 / s4 |
| MP-E4-C8-T02 | Concepts page: conversations, retention, secrets | blocked | DESIGN-E4, C1-T03 | 3 / s4 |

Counts per chunk: C1 4 · C2 2 · C3 3 · C4 2 · C5 4 · C6 2 · C7 1 · C8 2 = 20
(1 ready, 19 blocked).

## Dependency order

```text
C1-T00 ─► C1-T01 ─► C1-T02 ─┬─► C1-T03 ─┬─► C8-T01, C8-T02
                            │           ├─► C7-T01 (+ R6-C1-T01)
                            │           └─► C3-T02 ◄─ C3-T01 ◄─ (R6-C1-T01, C1-T01)
                            └─► C2-T01 ─┬─► C2-T02
                                        ├─► C5-T01 ─► C5-T02 ─► C5-T03 ─► C5-T04
                                        └─► C3-T02 ─┬─► C3-T03
                                                    ├─► C4-T01 ─► C5-T03
                                                    └─► C4-T02 (+ C5-T01) ─► C6-T02
MP-E7-C3-T03/T04 + C5-T01 ─► C6-T01 ─► (MP-E3-C5-T01 reuses its overlay)
MP-E3 consumes: C1-T02 (Ingest), C2-T01 (History), C5-T01/T02 (view), C6-T01 (overlay), C6-T02 (card)
```

## What may run concurrently

- C1-T00 now, with anything.
- After C1-T02: C1-T03, C2-T01 and (with R6-C1-T01) C3-T01 in parallel.
- After C2-T01: C2-T02, C5-T01, C7-T01 in parallel; C8-T01/T02 once C1-T03 is in.
- After C3-T02: C3-T03, C4-T01, C4-T02 in parallel; C5-T02 runs alongside.
- C6-T01 starts only after MP-E7-C3-T03/T04 (RC-05). C6-T02 does not wait for
  E7-C3 (Command answers do not follow listener mode; Phase D CR-E4-4).

## New research questions

- RQ-E4-6 (answered by census, re-measured in C3-T02): exact anchoring joins the
  bus event's `provenance.source_event_id` to a tool entry's id — 1,851 of 2,164
  completed publications matched (2026-10-06).
- RQ-E4-2 (answered for rule design in C3-T03; false-positive rate measured in
  its PR).
- RQ-E4-4 (answered for Codex; other backends recorded by C8-T01).
- RQ-E4-5 (verified by C1-T03 test + one manual SSH run).
- RQ-E4-3 (clock): resolved by design — both sides use daemon `observed_at`
  (contract §10–§11); no ticket.

Contract requests for other owners: [CONTRACT-REQUESTS.md](CONTRACT-REQUESTS.md).
