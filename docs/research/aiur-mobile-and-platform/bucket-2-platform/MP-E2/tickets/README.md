---
feature_id: MP-E2
base_sha: 45a290e3
researched: 2026-10-06
owner_gate: DESIGN-E2
contract: ../../../contracts/command-request-and-resolution.md
---

# MP-E2 tickets — Command capture, routing and escalation

36 tickets in 8 chunks: 2 spikes (`ready`, not executed) and 34 implementation tickets
(`blocked`). Every implementation ticket lists `DESIGN-E2` in `blocked_by` (pack rule).
DESIGN-E2's own header lets the backend-only tickets (C1, C2, C3-T01/T02, C4-T01..T05,
C5, C6-T01..T03) start before UX approval; whether to apply that relaxation is a
coordinator call. Tickets with a visible surface (C3-T03, C3-T04, C6-T04, C7-*) must wait
for approval regardless.

Binding inputs: D9–D12, RC-08 (`human-needed` topic registered by MP-R2-C5-T01),
RC-18 (live bug **#2819** is the legacy `attention.*` re-ask that never stops; C2-T03 cites
it and does not touch `decision_attention.ex`; #3005 `operator_relayed` is in flight and
C3-T02 works with or without it).

## Ticket table

| ID | Title | Status | Blocked by (besides DESIGN-E2) | Wave |
| --- | --- | --- | --- | --- |
| [C4-T00](MP-E2-C4-T00.md) | Spike R-Q1: Codex `request_user_input` through aiur's frames | ready | — | 0 |
| [C5-T00](MP-E2-C5-T00.md) | Spike R-Q2: Claude AskUserQuestion under aiur-claude | ready | — | 0 |
| [C1-T01](MP-E2-C1-T01.md) | v2 attributes in a `request_attributed` event | blocked | — | 1 |
| [C2-T05](MP-E2-C2-T05.md) | `decisions.escalation.*` config | blocked | DESIGN-E2 §6.1 defaults | 1 |
| [C3-T01](MP-E2-C3-T01.md) | Refuse Executor supersede of a human answer; ConflictSummary | blocked | — | 1 |
| [C1-T02](MP-E2-C1-T02.md) | Questions validation, short_label, suggested-responses warning | blocked | C1-T01 | 2 |
| [C1-T03](MP-E2-C1-T03.md) | Lifecycle topics by requester; rollback proof | blocked | C1-T01 | 2 |
| [C1-T04](MP-E2-C1-T04.md) | v2 fields in read API and `aiur commands --json` | blocked | C1-T01 | 2 |
| [C2-T01](MP-E2-C2-T01.md) | Pure routing/escalation policy | blocked | C1-T01 | 2 |
| [C3-T02](MP-E2-C3-T02.md) | Answering facade for human surfaces | blocked | C3-T01 | 2 |
| [C2-T02](MP-E2-C2-T02.md) | Routing facts and `human_needed` event | blocked | C1-T01, C1-T03 (+ MP-R2-C5-T01 if landed) | 3 |
| [C3-T03](MP-E2-C3-T03.md) | Dashboard replace / already-answered / too-late | blocked | C3-T02 | 3 |
| [C3-T04](MP-E2-C3-T04.md) | Stream Deck shows the winner | blocked | C3-T02 | 3 |
| [C4-T01](MP-E2-C4-T01.md) | NativeCapture core | blocked | C4-T00, C1-T01, C1-T02 | 3 |
| [C2-T03](MP-E2-C2-T03.md) | Routing process (cites #2819) | blocked | C2-T01, C2-T02, C2-T05 | 4 |
| [C2-T04](MP-E2-C2-T04.md) | `aiur executor-ack` + implicit acks | blocked | C2-T02 | 4 |
| [C4-T02](MP-E2-C4-T02.md) | Codex capture-and-hold (gated) | blocked | C4-T00, C4-T01 | 4 |
| [C5-T01](MP-E2-C5-T01.md) | aiur-claude forwards AskUserQuestion (sibling repo) | blocked | C5-T00, C4-T01 | 4 |
| [C7-T05](MP-E2-C7-T05.md) | Stream Deck v2 compatibility | blocked | C3-T04, C1-T04 | 4 |
| [C4-T03](MP-E2-C4-T03.md) | In-band delivery via the operator queue | blocked | C4-T02, C3-T02 | 5 |
| [C4-T04](MP-E2-C4-T04.md) | Release paths | blocked | C4-T02, C2-T02 | 5 |
| [C6-T01](MP-E2-C6-T01.md) | `aiur command request` | blocked | C1-T01, C1-T03, C2-T03 | 5 |
| [C7-T01](MP-E2-C7-T01.md) | Inbox chips, filters, banner, fleet column | blocked | C2-T03, C1-T04 | 5 |
| [C7-T02](MP-E2-C7-T02.md) | Detail timeline + multi-question form | blocked | C2-T02, C2-T04, C3-T02, C1-T02 | 5 |
| [C7-T03](MP-E2-C7-T03.md) | Unit row "waiting for your answer" | blocked | C4-T02 | 5 |
| [C7-T04](MP-E2-C7-T04.md) | `aiur commands` columns and filters | blocked | C2-T03, C1-T04 | 5 |
| [C8-T03](MP-E2-C8-T03.md) | Agent skill + census + flip | blocked | C1-T02, C4-T02 | 5 |
| [C4-T05](MP-E2-C4-T05.md) | Codex feature flag + capability | blocked | C4-T00, C4-T04 | 6 |
| [C5-T02](MP-E2-C5-T02.md) | aiur Claude handler + min version | blocked | C5-T01, C4-T03, C4-T04 | 6 |
| [C6-T02](MP-E2-C6-T02.md) | Executor delivery via journal and wake inbox | blocked | C6-T01, C2-T02 | 6 |
| [C6-T04](MP-E2-C6-T04.md) | Dashboard "From Executor" filter | blocked | C6-T01, C1-T04 | 6 |
| [C5-T03](MP-E2-C5-T03.md) | Claude release on multi-call / lost session | blocked | C5-T02 | 7 |
| [C6-T03](MP-E2-C6-T03.md) | `aiur ask` alias | blocked | C6-T01, C6-T02 | 7 |
| [C8-T01](MP-E2-C8-T01.md) | Concept docs | blocked | C2-T03, C3-T03, C4-T04, C6-T02 | 7 |
| [C8-T02](MP-E2-C8-T02.md) | aiur-run skill | blocked | C2-T04, C6-T02, C7-T04 | 7 |
| [C8-T04](MP-E2-C8-T04.md) | Enable native capture defaults (owner) | blocked | C4-T05, C5-T03, C7-T03 + owner flag decision | 8 |

Wave = longest predecessor chain inside MP-E2 (spikes = 0). External predecessors:
MP-R2-C5-T01 (catalog, RC-08) for C2-T02 if it lands first; MP-R7-C2-T2 (reserved
callbacks) for C4/C5 — otherwise the pre-R7 rule (plan §9: one call site in
`codex/approvals.ex`, new code in `Aiur.Commands.NativeCapture.*`); MP-R1 identity
(`session_ref`) for C1-T01 (nil until then); U3 owner notice for C6-T02.

## Dependency order

```text
C4-T00 ─┐                  C5-T00 ─┐
C1-T01 ─┼─► C1-T02 ─┬──────► C4-T01 ─┬─► C4-T02 ─┬─► C4-T03 ─┬─► C5-T02 ─► C5-T03 ─┐
        │           │                └─► C5-T01 ─┼───────────┘                     │
        ├─► C1-T03 ─┴─► C2-T02 ─┬─► C2-T03 ─┬─► C6-T01 ─► C6-T02 ─┬─► C6-T03      │
        │                       │           ├─► C7-T01             ├─► C8-T02      │
        ├─► C1-T04              │           └─► C7-T04 ────────────┘               │
        └─► C2-T01 ─────────────┘   C2-T05 ──┘                                     │
                                 ├─► C2-T04 ─► C7-T02                               │
                                 └─► C4-T04 (with C4-T02) ─► C4-T05 ─► C8-T04 ◄─────┘
C3-T01 ─► C3-T02 ─┬─► C3-T03 ─► (C8-T01)
                  ├─► C3-T04 ─► C7-T05
                  └─► C4-T03, C7-T02
C4-T02 ─► C7-T03, C8-T03
```

## What may run concurrently

- Both spikes, any time (no repository change).
- Wave 1: C1-T01, C2-T05, C3-T01 touch disjoint files (decision.ex/event/projection vs
  config schema vs supersede guard) — parallel.
- Wave 2: C1-T02 (validation), C1-T03 (topics), C1-T04 (serializers), C2-T01 (pure
  module), C3-T02 (facade) — parallel; C1-T03 and C1-T04 both read `Requester` but edit
  different files.
- C3 (answers) runs beside C2 (routing) throughout.
- C4 and C6 chains are independent of each other.
- **Conflict hot spots** (serialize PRs touching the same file): `decision_store.ex`
  (C1-T01, C1-T03, C2-T02, C2-T03 defer guard, C3-T01, C6-T01, C6-T02), `decision_event.ex`
  / `decision_projection.ex` (C1-T01 then later fact-type additions only extend
  `Aiur.Commands.EventData`), `streamdeck_channel.ex` (C3-T04, C7-T05), dashboard
  decision components (C3-T03, C6-T04, C7-T01, C7-T02).

## Research questions raised in Phase C

- **R-Q1** → spike C4-T00. **R-Q2** → spike C5-T00.
- **R-Q3 answered** (C2-T04): ack = explicit `executor-ack` + Executor actions only.
- **R-Q4 answered** (C1-T01/T03): unknown event types are retained and skipped by older
  binaries (`decision_event.ex:167-193`); new fields therefore travel in new event types,
  never in the `requested` snapshot (hash recomputed on replay) and never as a `nil`
  ticket.
- **R-Q5** (#3005): open; C3-T02 handles both outcomes.
- **RQ-E2-1 (new):** `claude-repl` (Remote Control transport) native capture — the REPL
  shows AskUserQuestion in its own pane; whether aiur should capture it (blocking hook,
  harness-adapter §6 item 5) is left to MP-E3/MP-E7. MP-E2 reports `:none`.

Contract requests for the coordinator: [CONTRACT-REQUESTS.md](CONTRACT-REQUESTS.md).
