---
design_task: DESIGN-N6
feature_id: MP-N6
owner: Kevin (operator)
status: open — not approved
blocks: MP-N6-C2..C6 (see ../bucket-3-mobile-watch/MP-N6/chunks.md)
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
  Proposal: no — keep the draft and require a manual Retry.
- **D-2** Extra Face ID / unlock prompt before submitting (OQ-N6-2)? Proposal: no extra
  prompt beyond the OS unlock.
- **D-3** Converse on the watch, or hand off to the phone (OQ-N6-3)? Decide with DESIGN-N7.
- **D-4** Multi-question native Commands on phone and watch (follows DESIGN-E2 §6.5);
  proposal: the watch shows "Answer on phone" for multi-question Commands.
- **D-5** Show option details (benefits, drawbacks, risk) on the watch at all? Proposal: no.

## 5. States to design (phone and watch)

Loading · loaded · submitting · accepted/delivering · delivered · already answered ·
Executor answer pending (Replace) · too late to replace · no longer needed · stale
(changed underneath) · unreachable/offline · not paired / revoked · Command not found ·
instance changed · voice unavailable · mic permission denied · `commands.answer`
unavailable ("answer from the dashboard").

## 6. Acceptance conditions

- Every state in §5 has a phone design and, where applicable, a watch design.
- Layouts reuse DESIGN-E2 and DESIGN-E5 decisions without contradiction (the reviewer
  checks copy and option rules against those tasks).
- D-1…D-5 recorded with Kevin's answers.
- Kevin explicitly approves. Nobody else marks this task complete.
