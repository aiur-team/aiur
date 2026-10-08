---
design_task: DESIGN-R6
feature_id: MP-R6
owner: Kevin
status: approved by the Executor 2026-10-08 per EXECUTOR-APPROVALS.md (Kevin may revise); the hardware re-proof pass itself needs Kevin's deck
blocks: [MP-E4-C7-T01, MP-R5-C1-T03, MP-R6-C1-T01, MP-R6-C2-T01, MP-R6-C3-T01]
blocks_note: "Phase D: the list is the tickets whose blocked_by names DESIGN-R6 (waived entries excluded). Earlier wording: every MP-R6 implementation ticket (MP-R6-C1..C3)"
base_main_sha: 45a290e3
date: 2026-10-06
related_plan: ../bucket-1-refactor/MP-R6/plan.md
linked_design_tasks: DESIGN-E4 (conversation layout and event navigation; anchors are reused there)
---

Executor decisions recorded in [EXECUTOR-APPROVALS.md](EXECUTOR-APPROVALS.md) (2026-10-08).

# DESIGN-R6 — Kevin: confirm that the Stream Deck split changes nothing you see

**MP-R6 implementation is blocked until this task is approved.** Research and
planning may continue. Do not mark this task complete without Kevin's
explicit written approval.

## 1. What this gate confirms

- [x] (Executor, 2026-10-08) **No change on the physical deck.** These all behave identically:
  - the grid, `cmd`, logs, settings and commands modes;
  - key faces, colours and badges;
  - touch-strip content;
  - the logs paging, with 7 events plus a pinned LIVE key;
  - the "Ticket opened" origin key.
- [x] (Executor, 2026-10-08) **Hold-to-dictate preserved.** Hold Mic to record, release to
  transcribe; text accumulates across holds; Send delivers it to the
  focused agent; Cancel clears it.
- [x] (Executor, 2026-10-08) **Targeting preserved.**
  - Pressing an agent key focuses it, and every action targets the focused
    agent.
  - The commands mode answers only the focused agent's Commands.
  - Dictated answers stay attributed to the `streamdeck` operator actor.
  - The Executor is never a deck target.
- [x] (Executor, 2026-10-08) **No change in the `/streamdeck` browser emulator** in the dashboard.
- [x] (Executor, 2026-10-08) **Setup unchanged.** The same sidecar install, `streamdeck.env`
  (`AIUR_PHOENIX_URL`, dashboard credentials), udev rule and systemd unit.

## 2. Decisions needing your input

1. Is a hardware re-proof on your own deck required before the
   contract-ownership change (C2) merges? Recommended: **required, one manual
   pass**, because the deck is your daily surface and one pass is cheap.
   [x] required (Executor, 2026-10-08)  [ ] emulator plus automated tests are enough.
2. Should the event→transcript grouping the deck uses ("each line belongs to
   the last event at or before it") also be the starting rule for dashboard
   conversation navigation? This decision is final in DESIGN-E4; recording
   your initial view helps the E4 planner. Recommended: **yes, start there**,
   because the rule is already proven on the deck and E4 can still refine it.
   [x] yes, start there (Executor, 2026-10-08)  [ ] no / discuss.

## 3. States

There are no new screens and no new states.

## 4. Acceptance

The gate is complete when every box in § 1 is approved and the § 2 answers
are recorded.
