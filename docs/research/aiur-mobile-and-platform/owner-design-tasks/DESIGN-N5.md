---
design_task: DESIGN-N5
feature_id: MP-N5
owner: Kevin (operator)
status: open — not approved
blocks: MP-N5-C4 and the user-visible copy in MP-N5-C1/C3 (see ../bucket-3-mobile-watch/MP-N5/chunks.md)
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
| Phone: Notifications (machine level) | defaults list, OS permission status, link to OS settings |
| Phone: per-instance override | reached from the instance (DESIGN-N3) or the machine screen |
| Unavailable option row | disabled control + reason + optional "how to enable" |
| Progress step picker | off / 10 % / 25 % / 50 %, completion toggle |
| Opt-in events list | PR merged, Agent gave up (retry exhausted), CI failed |
| Watch (only if it receives pushes directly) | with DESIGN-N7 |

## 3. Decisions that need Kevin

- **D-1** May one instance's blocker Commands be muted on a device (OQ-N5-1)? Proposal:
  yes, with a visible "muted" badge on the instance in the meta-dashboard.
- **D-2** Reminder for an unanswered blocking Command (OQ-N5-2)? Proposal: none in v1.
- **D-3** Offer commit-push and comment notifications (OQ-N5-3)? Proposal: not in v1.
- **D-4** Non-blocking Commands that need you: on by default (proposal) or opt-in (OQ-N5-4)?
- **D-5** Re-notify when a reopened build order completes again (OQ-N5-5)? Proposal: yes.
- **D-6** aiur quiet hours, or OS Focus only (OQ-N5-6)? Proposal: OS Focus only.
- **D-7** Wording of the digest and of each option.
- **D-8** Executor-created build queues (MP-E1): do their milestones follow the build-order
  progress setting (proposal) or get their own toggle (OQ-N5-7)?

## 4. States to design

Loading · loaded · saving · saved · save conflict (changed from another app instance) ·
instance offline (stale values, save disabled for that instance) · machine unreachable ·
OS notifications denied · option unavailable (each reason) · device unpaired.

## 5. Acceptance conditions

- Every surface and state above has a design.
- D-1…D-8 recorded with Kevin's answers.
- Kevin explicitly approves. Nobody else marks this task complete.
