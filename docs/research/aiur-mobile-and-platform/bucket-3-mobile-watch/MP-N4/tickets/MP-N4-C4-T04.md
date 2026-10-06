---
ticket_id: MP-N4-C4-T04
feature_id: MP-N4
chunk_id: MP-N4-C4
bucket: 3-mobile-watch
title: iOS retraction — remove delivered notifications listed in `retracts`
status: blocked
blocked_by: [DESIGN-N4 (D-4), OQ-N4-3, RQ-N4-5, MP-N4-C4-T03]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N5 (emits command.resolved), MP-N6-C6 (foreground reconcile)]
prior_findings: [E-A7, plan §7.4]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C4-T04 — iOS retraction

## Identity and outcome

Bucket 3, MP-N4, chunk C4. When an accepted payload has `retracts: [nid…]` (sent by
MP-N5 as `command.resolved`, normal priority, same `collapse_token`), remove the listed
delivered notifications and present the retraction per DESIGN-N4 D-4.

## Dependencies and blockers

**Blocked** on three items that change what is built:
- **RQ-N4-5** (device test V-I6): can an NSE call
  `UNUserNotificationCenter.removeDeliveredNotifications(withIdentifiers:)` for other
  notifications? Apple documentation does not say (platform-evidence.md, RQ list).
- **OQ-N4-3**: filtering entitlement applied for and granted? Without it the retraction
  itself is displayed (as a quiet passive line).
- **DESIGN-N4 D-4**: silent removal vs "Answered on <surface>" line.
- C4-T03 (identifiers: the request identifier of each delivered notification must be its
  `nid`, set there).

Fallback that works regardless: MP-N6-C6-T02 reconciles delivered notifications on app
foreground using `getDeliveredNotifications` from the app process (documented API in the
main app), so a missed retraction degrades to "Already resolved" on open (plan §7.4).

## Verified starting point

- Contract v2 §3 `retracts`, §6 device rules ("apply `retracts` by removing the listed
  delivered notifications").
- E-A7 (filtering entitlement), plan §7.4.

## Chosen design

Pending RQ-N4-5. Two candidate implementations, chosen by the V-I6 result:
(a) NSE removes listed ids and returns empty content (entitlement) or a passive line;
(b) NSE cannot remove → the retraction payload is shown passively and the app removes on
next foreground (MP-N6-C6-T02).

## Implementation steps

n/a until unblocked.

## Non-happy paths

Retraction arrives before the original (reorder, E-A2): store the retracted `nid` in
`SeenStore` so the late original is dropped as seen.

## Compatibility and rollout

n/a until unblocked.

## Verification

When unblocked: XCTest for "late original after retraction is dropped" (must fail without
the SeenStore write); device V-I6, V-M1.

## Completion and handoff

- [ ] RQ-N4-5 result recorded in platform-evidence.md; OQ-N4-3 and D-4 answers recorded.
