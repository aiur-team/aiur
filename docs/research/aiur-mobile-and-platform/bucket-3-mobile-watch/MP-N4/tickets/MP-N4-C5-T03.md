---
ticket_id: MP-N4-C5-T03
feature_id: MP-N4
chunk_id: MP-N4-C5
bucket: 3-mobile-watch
title: Android channels, notification rendering, POST_NOTIFICATIONS flow and force-stop warning
status: blocked
blocked_by: [DESIGN-N4 (D-1, D-2, D-5, §4 states), DESIGN-E2 §4.1, MP-N4-C5-T02, RQ-N4-9]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N1]
prior_findings: [E-F7, E-F8]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C5-T03 — Android presentation and permission states

## Identity and outcome

Bucket 3, MP-N4, chunk C5. Create the channels (Commands, Progress, Other — DESIGN-N4
§2), map accepted payloads to `NotificationCompat` (title, subtitle as sub-text or
content text per design, group per instance, tag = `nid`, tap `PendingIntent` carrying
the destination to MP-N6-C2), the `POST_NOTIFICATIONS` request flow (Android 13+, E-F8),
reporting `notifications_permitted` to the machine (C5-T05 record field), and the
force-stopped warning (E-F7).

## Dependencies and blockers

**Blocked** on design content: DESIGN-N4 D-1 (fallback copy), D-2 (copy per kind), D-5
(grouping), §4 states (permission denied, force-stopped); DESIGN-E2 §4.1 (title fallback).

**RQ-N4-9 (new):** how the app detects that it was force-stopped. Candidate:
`ApplicationExitInfo.REASON_USER_REQUESTED` via `ActivityManager.getHistoricalProcessExitReasons`
(API 30+) — not verified in Phase C; E-F7 itself is a search summary to be re-read
(platform-evidence.md). The detection method changes code, so it blocks that part.

## Verified starting point

- E-F8: `POST_NOTIFICATIONS` runtime permission from API 33; notifications off by default
  for new installs (developer.android.com, updated 2026-10-01).
- E-F7: force-stopped apps receive no messages until reopened (still a search summary;
  Phase D m10: C5-T01 re-reads the FCM troubleshooting page and the Android "stopped
  state" docs; V-A4 decides).

## Chosen design (fixed parts)

- **Channel ids** (Android `NotificationChannel`, one per user-controllable stream):
  `aiur.commands`, `aiur.progress`, `aiur.other`. **Category ids** (contract §3.1 rule 5,
  shared with iOS and the watch): `aiur.command`, `aiur.progress`, `aiur.other`, set as
  the intent extra `aiur.category`. Channel ids and category ids are different names on
  purpose: a channel is an OS user setting, a category is the cross-platform kind key
  (Phase D X-56). Mapping: kind `command.*` → channel `aiur.commands`, category
  `aiur.command`; `progress.*` → `aiur.progress` / `aiur.progress`; everything else →
  `aiur.other` / `aiur.other`. Importance per DESIGN-N4.
- Permission requested only after pairing, never at first launch (DESIGN-N2/N4 timing).
- No action buttons (DESIGN-N6: no answering from the banner).
- **Lock screen (Phase D security m9):** every posted notification has
  `setVisibility(VISIBILITY_PRIVATE)` and `setPublicVersion(<uniform fallback>)` while
  `hideBodyWhenLocked` is on (default `true` until DESIGN-N4 answers).
- **Badge (Phase D M3):** `setNumber(summary.badge)` when present; reminder (`attempt: 2`)
  re-posts with the same tag (`stream`-derived) so it replaces the first.
- **Fallback with key loss (M6):** a `Fallback(KEYS_UNAVAILABLE)` result posts the uniform
  fallback on `aiur.other`; its tap opens the in-app "Open aiur to re-pair" state.

## Implementation steps

Build now; only copy strings and channel importance wait for DESIGN-N4.

1. `aiur-client-core/src/main/kotlin/push/Presentation.kt` (PROPOSED): pure
   `present(result: AcceptResult, settings: PresentationSettings): PostPlan`.
2. `aiur-client-core/src/main/kotlin/push/Channels.kt`: channel definitions; copy in
   `res/values/notification_strings.xml` with placeholders marked `DESIGN-N4 D-2 pending`.
3. `aiur-client-core/src/main/kotlin/push/PermissionState.kt`: `POST_NOTIFICATIONS`
   state (API 33+), reported as `notifications_permitted` through C5-T05.
4. `aiur-client-core/src/main/kotlin/push/ForceStopDetector.kt`: **blocked part** —
   implemented only after RQ-N4-9 cites a dated developer.android.com page (candidate
   `ActivityManager.getHistoricalProcessExitReasons` / `REASON_USER_REQUESTED`, API 30+).
   Until then the class is not created and the warning state is not shown.
5. N1 shell hooks for the permission screen and the force-stop banner.

## Non-happy paths

- Permission denied: notifications not shown; registration still reports
  `notifications_permitted: false` so the machine shows "phone notifications blocked".
- Channel disabled by user: OS drops; app settings screen shows it (DESIGN-N5 surface).
- API < 30 (if MP-N1's min SDK allows it): force-stop detection unavailable → no warning,
  never a false warning.

## Compatibility and rollout

API 33 permission path vs older (no runtime permission).

## Verification

`aiur-client-core/src/test/kotlin/push/PresentationTest.kt` and
`PermissionStateTest.kt` (PROPOSED, Robolectric). Test names carry the DESIGN-N4 decision
or §4 state:

| Test | Expected | Must fail without |
| --- | --- | --- |
| `d2_commandKindPostsOnCommandsChannelWithCommandCategory` | channel `aiur.commands`, extra `aiur.category == "aiur.command"` | use the category id as channel id |
| `s4_unknownKindIsOther` | `aiur.other` / `aiur.other` | map to Commands |
| `s4_permissionDeniedReportsNotPermitted` (API 33 shadow) | `notifications_permitted == false` | report `true` when denied |
| `s4_fallbackKeysUnavailableOpensRepair` | post on `aiur.other`, tap intent = repair route | drop the post |
| `m9_hideBodyWhenLockedSetsPrivateWithFallbackPublicVersion` | `VISIBILITY_PRIVATE`, public version text = fallback | `VISIBILITY_PUBLIC` |
| `m3_badgeSetsNumber` / `m3_reminderReplacesByTag` | `number == 3` / same tag, one active notification | new tag per attempt |
| `s4_forceStopWarning` (added only with step 4) | warning state after a recorded `REASON_USER_REQUESTED` exit | always false |

Commands: `./gradlew :aiur-client-core:testDebugUnitTest --tests '*PresentationTest*'
--tests '*PermissionStateTest*'` (in the generated `android/`, per MP-N1-C1). Device:
V-A1, V-A2b, V-A4 (force-stop warning), V-K1, V-LS1, A3 slot (API 33) in C7.

## Completion and handoff

- [ ] DESIGN-N4 answers applied; RQ-N4-9 evidence (dated developer.android.com page)
  recorded before step 4 starts.
- Docs: `website/docs-app/guide/` notifications page (Android channels, permission,
  force-stop warning, lock-screen privacy).
- Dependents: MP-N4-C7, MP-N5-C4 (permission state surfacing).
