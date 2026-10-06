---
ticket_id: MP-N6-C6-T02
feature_id: MP-N6
chunk_id: MP-N6-C6
bucket: 3-mobile-watch
title: Foreground reconciliation — remove delivered notifications for Commands no longer needing you
status: ready
blocked_by: [DESIGN-N6, DESIGN-N4 (D-4 retraction presentation, informs only), MP-N6-C1-T02, MP-N4-C4-T02, MP-N4-C5-T02, RQ-TRANSPORT (RC-15)]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N4]
prior_findings: [N4 plan §7.4 (missed retraction degrades to reconcile on open), E-A4/E-F2 (push is not a queue)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C6-T02 — Foreground reconciliation

## Identity and outcome

Bucket 3, MP-N6, chunk C6. On app foreground (and on cold start after pairing loads), for
each paired instance: fetch `GET /api/v1/device/commands?state=needs_you` (C1-T02), list
delivered notifications (iOS `UNUserNotificationCenter.getDeliveredNotifications` from the
app process; Android `NotificationManager.getActiveNotifications`), and remove every
delivered Command notification whose `decision_id` is not in the needs-you list. This is
the guaranteed path behind best-effort push retraction (MP-N4-C4-T04/C5-T04).

## Dependencies and blockers

- C1-T02; MP-N4 acceptance pipelines (they stamp each delivered notification with
  `decision_id` in `userInfo`/extras and `nid` as identifier/tag).
- DESIGN-N4 D-4 decides how a *push* retraction looks; foreground removal is silent in all
  proposals, so this ticket is not blocked by it. DESIGN-N6 gate.
- RQ-TRANSPORT (calls the instance).

## Verified starting point

N4 plan §7.4 ("The app re-checks state on open regardless, so a missed retraction degrades
to 'Already resolved'"); E-A4, E-F2 (storage limits).

## Chosen design

- Only removes; never adds notifications (no local re-notification of missed pushes —
  the in-app list shows them).
- Unreachable instance → leave its notifications untouched (unknown ≠ resolved).

## Implementation steps

`reconcileDelivered.ts` (PROPOSED) + native bridges for the two OS listing APIs (N1
`AiurNative` module).

## Non-happy paths

Needs-you call fails → no removal for that instance (unknown-path rule).

## Compatibility and rollout

n/a.

## Verification

```text
npm --prefix packages/aiur-mobile test -- test/notifications/reconcileDelivered.test.ts
```

| Test | Expected | Must fail without |
| --- | --- | --- |
| `resolvedCommandNotificationRemoved` | delivered notification whose Command is not in `needs_you` is removed | the removal |
| `unreachableInstanceKeepsNotifications` | probe failure → nothing removed | the unknown-path rule (failure treated as an empty list → fails) |
| `neverAddsNotifications` | reconciliation posts no local notification | the remove-only rule |

Device V-M1, V-M2.

## Completion and handoff

- [ ] Dependents: MP-N4-C7-T02.
- [ ] Docs: none, because it only removes notifications for Commands already resolved;
  the notification behaviour is documented by MP-N4 (`website/docs-app/guide/mobile.md`).
