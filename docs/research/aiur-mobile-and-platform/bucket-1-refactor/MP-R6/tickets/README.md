# MP-R6 tickets

- **U0 gate (X-58, RC-19).** Every MP-R6 ticket waits for U0 review of the prior plan
  (`docs/plans/2026-09-29-001-refactor-production-readiness-plan.md`), because RC-19 keeps
  that gate for refactor work. U0 has no ticket ID, so the gate is stated here and not in
  `blocked_by`; the MP-R1-C11-T02 recheck does not replace it.

Base `45a290e3`, researched 2026-10-06. RC-06 is applied: **R6-C1 extracts**
the neutral anchor module without changing behaviour, MP-E4-C3 extends it, and
MP-E4-C7 moves the deck onto the E4 journal. RC-07 is also applied: the E4
journal position is the anchor address, so R6 keeps the deck's row-index
`start` unchanged.

| ID | Title | Status | Blocked by | Wave |
| --- | --- | --- | --- | --- |
| [MP-R6-C1-T01](MP-R6-C1-T01.md) | Extract the event→transcript anchor rule into `Aiur.Conversation.Anchors` | blocked | DESIGN-R6 | 1 |
| [MP-R6-C2-T01](MP-R6-C2-T01.md) | The daemon owns the visual contract (`src/priv/streamdeck/`, sidecar mirror); core compiles without the package | blocked | DESIGN-R6, C1-T01 | 1 |
| [MP-R6-C3-T01](MP-R6-C3-T01.md) | Docs: shared projections versus deck presentation | blocked | DESIGN-R6, C1-T01, C2-T01 | 1 |

The voice delegation (plan C3-T02) is **not** a separate ticket here. It is
`MP-R5-C1-T03`, which moves the deck channel and projection onto `Aiur.Voice`
and carries the hold-to-dictate re-proof.

## Order and concurrency

```
C1-T01 ─► C2-T01 ─► C3-T01
MP-R5-C1-T03 (voice delegation) runs alongside; C3-T01 describes whatever has landed
C1-T01 ─► MP-E4-C3 (extends Anchors) ─► MP-E4-C7 (deck on the E4 journal)
```

- C1-T01 and C2-T01 both touch `streamdeck_key_face_contract.ex:14`. Run them
  in order.
- They may run in parallel with all MP-R5 tickets. R6 edits no file that R5
  edits.

## Plan research answered

- **RQ1:** no stable per-entry ID exists:
  - `msg_id`/`turn_id` come from the provider and may be nil;
  - `AgentEvents` uses `:erlang.unique_integer` per BEAM (`agent_events.ex:129`).

  So R6 keeps `start`, and E4's journal supplies `pos`.
- **RQ2:** the canonical file lives in `src/priv/streamdeck/`. The sidecar keeps
  a byte-checked mirror, because `tsconfig` `rootDir: src` forbids importing
  from outside `src`.
- **RQ3:** `StreamDeckGrid.dependency_ready?/2` has no outside consumer; the
  only mention is a comment at `status_report.ex:1452`. It stays in place.

## Owner items in DESIGN-R6 that affect tickets

- **§2.1, hardware re-proof before C2:** decides which manual check C2-T01 and
  MP-R5-C1-T03 record.
- **§2.2, deck grouping as the dashboard starting rule:** informs MP-E4. It
  does not block R6.
