---
design_task: DESIGN-N5
feature_id: MP-N5
owner: Kevin (operator)
status: open — not approved
blocks: [MP-N5-C1-T01, MP-N5-C1-T02, MP-N5-C1-T03, MP-N5-C1-T04, MP-N5-C1-T05, MP-N5-C2-T00, MP-N5-C2-T01, MP-N5-C2-T02, MP-N5-C2-T03, MP-N5-C2-T04, MP-N5-C3-T01, MP-N5-C3-T02, MP-N5-C3-T03, MP-N5-C4-T01, MP-N5-C4-T02, MP-N5-C4-T03, MP-N5-C5-T01]
blocks_note: "Phase D: the list is the tickets whose blocked_by names DESIGN-N5 (waived entries excluded). Earlier wording: MP-N5-C4 and the user-visible copy in MP-N5-C1/C3 (see ../bucket-3-mobile-watch/MP-N5/chunks.md)"
shared_with: DESIGN-N4 (presentation), DESIGN-N3 (instance list), DESIGN-E2 §6.2 (which Commands count as "needs you"), DESIGN-N7 (watch, if it has its own settings)
base_main_sha: 45a290e3
date: 2026-10-06
---

# DESIGN-N5 — Kevin: design and approve notification preferences

Deliver the settings screens, states, copy and an explicit approval.
**MP-N5 user-visible implementation stays blocked until this task is approved.** The
preference store and policy engine (MP-N5-C1 API, C2, C3 logic) may proceed.

## 1. Settled inputs

- D18 defaults: Commands that need you — always on; build-order progress every 25 % and
  completion — on; PR merges and other events — opt-in.
- Preferences are **per paired device, per machine**, with optional per-instance
  overrides ([MP-N5 plan](../bucket-3-mobile-watch/MP-N5/plan.md) §4).
- Options the instance cannot deliver are shown **unavailable with a reason**, never as a
  working toggle (e.g. "Build orders are not installed on this instance").

## 2. Surfaces

| Surface | Design |
| --- | --- |
| Phone: Notifications (machine level) | defaults list, OS permission status, link to OS settings, blocker reminder setting (D-2: off / 15 / 30 / 60 min) |
| Phone: per-instance override | reached from the instance (DESIGN-N3) or the machine screen |
| Unavailable option row | disabled control + reason + optional "how to enable" |
| Progress step picker | off / 10 % / 25 % / 50 %, completion toggle |
| App icon badge switch (D-9) | on/off, and the count it shows |
| Opt-in events list | PR merged, Agent gave up (retry exhausted), CI failed |
| Watch (only if it receives pushes directly) | with DESIGN-N7 |

## 3. Decisions that need Kevin

- **D-1** May one instance's blocker Commands be muted on a device (OQ-N5-1)? Proposal:
  yes, with a visible "muted" badge on the instance in the meta-dashboard. **Accepting this
  amends D18**, which says blocker Commands are "always on" (Phase D, X-57); record the
  amendment in `context-and-decisions.md` if accepted.
- **D-2** Reminder for an unanswered blocking Command (OQ-N5-2). This is a delivery
  reliability question, not only a noise question: APNs and FCM are best effort and return
  no display receipt, so a dropped `human_required` push is noticed only when you open the
  app (Phase D, feasibility M3). Options: (a) none in v1; (b) **one bounded reminder** for a
  blocking Command still waiting for you after N minutes (default 30), with the same
  collapse token so it replaces the first notification rather than stacking.
  Recommended: **(b), one reminder at 30 min**, because it is the only recovery for a lost
  blocker push. Setting `commands_reminder_minutes` ∈ {off, 15, 30, 60}, default 30; the
  reminder replaces the first notification and is never sent after the Command is
  resolved. If you refuse it, MP-N4 AC-N4-1 records the accepted risk. Implemented in
  MP-N5-C1-T01 and C2-T02.
- **D-3** Offer commit-push and comment notifications (OQ-N5-3)? Proposal: not in v1.
- **D-4** Non-blocking Commands that need you: on by default (proposal) or opt-in (OQ-N5-4)?
- **D-5** Re-notify when a reopened build order completes again (OQ-N5-5)? Proposal: yes.
- **D-6** aiur quiet hours, or OS Focus only (OQ-N5-6)? Proposal: OS Focus only.
- **D-7** Wording of the digest and of each option. Recommended: reuse the dashboard terms
  ("Commands that need you", "build order", "PR merged") and the D18 phrasing, because the
  same words then mean the same thing on the dashboard and the phone.
- **D-8** Executor-created build queues (MP-E1): do their milestones follow the build-order
  progress setting (proposal) or get their own toggle (OQ-N5-7)?
- **D-9** App icon badge (Phase D; handed over from DESIGN-N3 Q5, which links here). Should
  the app icon show a number: the open **blocking** Commands that need you (DESIGN-E2 §6
  item 2 "Needs you"), summed on the device across every paired machine? It is a number
  only, never an inbox. Options: (a) on by default; (b) off by default; (c) no badge.
  Recommended: **(a) on by default, with a switch on the machine screen**, because the
  badge is the cheapest way to see a waiting blocker. Payload field `summary.badge`
  (notification contract §3); implemented by MP-N4-C4-T03 and C5-T03.

## 4. States to design

Loading · loaded · saving · saved · save conflict (changed from another app instance) ·
instance offline (stale values, save disabled for that instance) · machine unreachable ·
OS notifications denied · option unavailable (each reason) · device unpaired.

## 5. Acceptance conditions

- Every surface and state above has a design.
- Every decision in §3 (D-1…D-9, including the D-2 blocker reminder and the D-9 app badge)
  recorded with Kevin's answers.
- Kevin explicitly approves. Nobody else marks this task complete.
