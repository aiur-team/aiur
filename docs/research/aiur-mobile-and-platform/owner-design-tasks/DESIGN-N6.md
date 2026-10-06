---
design_task: DESIGN-N6
feature_id: MP-N6
owner: Kevin (operator)
status: open — not approved
blocks: [MP-N1-C4-T04, MP-N6-C1-T00, MP-N6-C1-T01, MP-N6-C1-T02, MP-N6-C1-T03, MP-N6-C1-T04, MP-N6-C2-T01, MP-N6-C2-T02, MP-N6-C2-T03, MP-N6-C3-T01, MP-N6-C3-T02, MP-N6-C3-T03, MP-N6-C4-T01, MP-N6-C5-T01, MP-N6-C5-T02, MP-N6-C5-T03, MP-N6-C6-T01, MP-N6-C6-T02, MP-N7-C1-T04, MP-N7-C2-T03, MP-N7-C2-T06, MP-N7-C3-T03, MP-N7-C4-T01, MP-N7-C4-T02]
blocks_note: "Phase D: the list is the tickets whose blocked_by names DESIGN-N6 (waived entries excluded). Earlier wording: MP-N6-C2..C6 (see ../bucket-3-mobile-watch/MP-N6/chunks.md)"
depends_on_design: DESIGN-E2 (shared Command presentation, normative), DESIGN-E5 (mic and Dictate/Converse controls, normative), DESIGN-N7 (watch layout), DESIGN-N4 (what the tapped notification looked like), DESIGN-E4 (conversation anchor view)
base_main_sha: 45a290e3
date: 2026-10-06
---

# DESIGN-N6 — Kevin: design and approve the phone and watch Command response flow

Deliver the phone and watch screens for "notification → Command context → answer",
their states and copy, and an explicit approval.
**MP-N6 user-visible implementation stays blocked until this task, DESIGN-E2 and
DESIGN-E5 are approved.** The device Command API (MP-N6-C1) may proceed.

## 1. What this task does not redefine

- **Command anatomy, option rules, routing chips, escalation timeline and answer-outcome
  copy** are designed once in [DESIGN-E2 §4–§6](DESIGN-E2.md). This task only lays them
  out for phone and watch.
- **The mic button behaviour and the Dictate / Converse choice** (D16: always an explicit
  choice, no default) are designed once in [DESIGN-E5](DESIGN-E5.md), with conversational
  mode in DESIGN-E6. This task only places the button and the choice sheet on phone and
  watch.

## 2. Fixed by plan and decisions

- Tap opens the Command, not an inbox and not the conversation; the conversation is one
  tap away at the Command's anchor.
- The mic is never active on tap; recording starts only after Mic → Dictate or Converse.
- No answering from the notification banner in v1.
- D11: first answer wins; a human may replace an undelivered Executor answer.
- Source: [MP-N6 plan](../bucket-3-mobile-watch/MP-N6/plan.md) §5.

## 3. Surfaces

| Surface | Design here |
| --- | --- |
| Phone Command screen | layout of DESIGN-E2 §4 blocks at phone width; sticky answer area; "Open conversation" |
| Phone outcome states | placement of DESIGN-E2 §4.4 outcomes; Replace confirmation |
| Phone unreachable state | sealed summary + "Can't reach <machine>" + Retry; draft kept |
| Phone landing from cold start | loading state, no inbox flash |
| Watch Command card | label, requester, question (2 lines), ≤ 3 options, Mic, "Open on phone" (with DESIGN-N7) |
| Watch outcome line | accepted / already answered / no longer needed / can't reach |
| Mic placement | phone and watch; choice sheet per DESIGN-E5 |

## 4. Decisions that need Kevin

- **D-1** Queue answers typed while offline for later automatic send (OQ-N6-1)?
  Proposal: **no on the phone** — keep the draft and require a manual Retry, because a late
  answer may land after the question changed. **The watch is the named exception** (Phase
  D, feasibility m6): a failed watch answer goes through `transferUserInfo` (MP-N7 plan
  §4/§8) and is re-sent later with its original idempotency key and `expected_version`, so
  a changed Command refuses it as stale (DV-W4b). Answering D-1 = no keeps that exception
  unless you also reject it, in which case MP-N7 drops the fallback.
  [ ] confirm both  [ ] no queueing anywhere (drop the watch fallback)
- **D-2** Extra Face ID / unlock prompt before submitting (OQ-N6-2)? Options: (a) no extra
  prompt beyond the OS unlock; (b) require a biometric or passcode check before each
  answer is submitted. Recommended: **(b) for writes** (Phase D, feasibility m9), because a
  lost phone stays authorized until someone revokes it on the machine (DESIGN-N2 Q4).
  Reading stays prompt-free.
- **D-3** Converse on the watch, or hand off to the phone (OQ-N6-3). **Answered in
  [DESIGN-N7 D-N7-3/D-N7-4](DESIGN-N7.md#3-decisions-needed-from-you)**; this gate only
  places the result.
- **D-4** Watch only: show "Answer on phone" for multi-question native Commands.
  Recommended: **yes**, because a stepper on a watch is too long. The multi-question layout
  for the dashboard and the phone is **answered in DESIGN-E2 §6 item 5**, not here.
- **D-5** Show option details (benefits, drawbacks, risk) on the watch at all? Proposal:
  **no**, because the watch card has two lines of context; details stay on the phone.

## 5. States to design (phone and watch)

Each state carries the key that MP-N6 tests are named after ([MP-N6 plan §5.5](../bucket-3-mobile-watch/MP-N6/plan.md)).
This gate owns copy and layout; the keys only name the state.

| Key | State | Key | State |
| --- | --- | --- | --- |
| `S01` | loading | `S10` | stale (changed underneath) |
| `S02` | loaded | `S11` | unreachable / offline |
| `S03` | submitting | `S12` | not paired / revoked |
| `S04` | accepted / delivering | `S13` | Command not found |
| `S05` | delivered | `S14` | instance changed |
| `S06` | already answered | `S15` | voice unavailable |
| `S07` | Executor answer pending (Replace) | `S16` | mic permission denied |
| `S08` | too late to replace | `S17` | `commands.answer` unavailable ("answer from the dashboard") |
| `S09` | no longer needed | `S18` | unlock to view (pairing store locked before first unlock; MP-N6-C2-T02) |

Voice states inside the Command screen (MP-N6-C4-T03; feasibility M2/M7):

- **Voice ended** — one state per row of the voice-session client error and end-reason
  table ([voice-session §8.1](../contracts/voice-session.md),
  [client errors](../contracts/voice-session-client-errors.md)): daily cap reached,
  provider quota, provider unavailable, connection lost, device unpaired, and the
  cause-neutral provider error / unknown. Retry appears only where that table allows it.
- **Draft stale** — the Command was answered elsewhere while a voice draft was open; show
  the winning answer.

## 6. Acceptance conditions

- Every state in §5 has a phone design and, where applicable, a watch design.
- Layouts reuse DESIGN-E2 and DESIGN-E5 decisions without contradiction (the reviewer
  checks copy and option rules against those tasks).
- Every decision in §4 recorded with Kevin's answers (D-1, D-2, D-4, D-5 here; D-3 in
  DESIGN-N7).
- Kevin explicitly approves. Nobody else marks this task complete.
