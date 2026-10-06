---
ticket_id: MP-N5-C4-T02
feature_id: MP-N5
chunk_id: MP-N5-C4
bucket: 3-mobile-watch
title: OS notification permission state on the settings screen and deep link to OS settings
status: blocked
blocked_by: [DESIGN-N5 (OS notifications denied state), DESIGN-N4 (permission copy), MP-N5-C4-T01, MP-N4-C4-T05, MP-N4-C5-T05]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N1, MP-N4]
prior_findings: [E-F8 (POST_NOTIFICATIONS), MP-N4 plan §7.2 permission row]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N5-C4-T02 — OS permission state

## Identity and outcome

Bucket 3, MP-N5, chunk C4. Read the OS notification authorization (iOS
`UNUserNotificationCenter.getNotificationSettings`; Android `areNotificationsEnabled` and
`POST_NOTIFICATIONS` on API 33+, E-F8) whenever the settings screen opens or the app
returns to foreground; show the DESIGN-N5 "OS notifications denied" state with a deep link
to the OS settings page; keep the machine informed by refreshing the
`notifications_permitted` flag in the push registration (MP-N4-C4-T05 / C5-T05, CR-N4-3).

## Dependencies and blockers

**Blocked** on DESIGN-N5 / DESIGN-N4 copy and placement for the denied state;
C4-T01 (screen exists); MP-N4 registration tickets (flag transport).

## Verified starting point

E-F8 (developer.android.com, updated 2026-10-01). iOS authorization APIs are the
UserNotifications framework (MP-N4 platform-evidence §A).

## Chosen design (fixed parts)

Never re-prompt automatically after a denial; only the explicit button opens OS settings.

## Implementation steps

After design approval: permission reader in the native cores, settings banner, foreground
refresh.

## Non-happy paths

Permission revoked while app closed → detected at next foreground; machine flag updated
then.

## Compatibility and rollout

Android < 33 has no runtime permission; channel-level disable still reported.

## Verification

Unit tests per permission state; device: A3 slot (API 33) and I1 in MP-N4-C7.

## Completion and handoff

- [ ] Copy from DESIGN-N5/N4. Dependents: C5-T01.
