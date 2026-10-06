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

Build now; only the denied-state copy and banner placement wait for DESIGN-N5 §4 /
DESIGN-N4.

1. iOS: `AiurClientKit/Sources/Push/PermissionReader.swift` (PROPOSED):
   `func read() async -> NotificationPermission` from
   `UNUserNotificationCenter.current().notificationSettings()`, mapping
   `.authorized | .provisional | .ephemeral → granted`, `.denied → denied`,
   `.notDetermined → notDetermined`, any other value → `unknown`.
2. Android: `aiur-client-core/src/main/kotlin/push/PermissionReader.kt`:
   `NotificationManagerCompat.areNotificationsEnabled()` plus, on API 33+,
   `POST_NOTIFICATIONS` grant state; per-channel disable from MP-N4-C5-T03 channels
   reported as `channelsDisabled: [id]`.
3. TS bridge `packages/aiur-mobile/src/native/permission.ts` and settings hook
   `src/screens/notifications/usePermissionState.ts`: refresh on screen open and on
   `AppState` → `active`; when the value changes, send the CR-N4-3 registration update
   with `notifications_permitted` (MP-N4-C4-T05 / C5-T05).
4. `src/screens/notifications/PermissionBanner.tsx`: the denied state with one explicit
   "Open settings" button (`Linking.openSettings()`); copy in `copy.ts` marked
   `DESIGN-N5 §4 pending`.

## Non-happy paths

- Permission revoked while app closed → detected at next foreground; machine flag updated
  then.
- Registration update fails (machine unreachable) → retried on the next foreground; the
  banner still shows (local truth first).
- `unknown` from the OS → the banner shows "Can't read notification permission", never
  "granted".

## Compatibility and rollout

Android < 33 has no runtime permission; `areNotificationsEnabled` and channel disable are
still reported.

## Verification

| Test file | Test (DESIGN-N5 §4 state) | Must fail without |
| --- | --- | --- |
| `AiurClientKitTests/PermissionReaderTests.swift` | `testS4_deniedMapsToDenied`; `testS4_unknownStatusIsUnknownNotGranted` | map the default branch to `granted` |
| `aiur-client-core/src/test/kotlin/push/PermissionReaderTest.kt` (Robolectric, SDK 33 and 32 shadows) | `s4_api33DeniedIsDenied`; `s4_api32ChannelDisabledReported` | ignore channel state |
| `packages/aiur-mobile/test/screens/notifications/usePermissionState.test.ts` | `§4 OS notifications denied: banner shown, no automatic re-prompt`; `permission change sends notifications_permitted update once` | call the OS prompt on mount / send on every foreground |

Commands: `xcodebuild test -scheme AiurClientKit -destination 'platform=iOS
Simulator,name=iPhone 16,OS=latest' -only-testing:AiurClientKitTests/PermissionReaderTests`;
`./gradlew :aiur-client-core:testDebugUnitTest --tests '*PermissionReaderTest*'`;
`npm --prefix packages/aiur-mobile test -- test/screens/notifications/usePermissionState.test.ts`.
Device: A3 slot (API 33) and I1 in MP-N4-C7.

## Completion and handoff

- [ ] Copy from DESIGN-N5/N4. Dependents: C5-T01.
- Docs: `website/docs-app/guide/` notifications page — "phone notifications blocked" and
  how to re-enable (via MP-N5-C5-T01).
