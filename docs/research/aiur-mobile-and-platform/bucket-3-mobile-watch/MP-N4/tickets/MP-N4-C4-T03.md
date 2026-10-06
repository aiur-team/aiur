---
ticket_id: MP-N4-C4-T03
feature_id: MP-N4
chunk_id: MP-N4-C4
bucket: 3-mobile-watch
title: iOS presentation mapping — title/subtitle/body, thread, category, interruption level
status: blocked
blocked_by: [DESIGN-N4 (D-2, D-3, D-5, D-1), DESIGN-E2 §4.1, MP-N4-C4-T02, OQ-N4-3]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N1, MP-E2]
prior_findings: [E-A7, E-A9]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C4-T03 — iOS presentation mapping

## Identity and outcome

Bucket 3, MP-N4, chunk C4. Map an accepted `ProtectedPayload` to
`UNMutableNotificationContent`: `title`, `subtitle`, `body`, `threadIdentifier`,
`categoryIdentifier`, `interruptionLevel`, `targetContentIdentifier` (destination), and
`userInfo["aiur.destination"]` (one key on both platforms; Android intent extra of the same name) for the tap handler (MP-N6-C2). Also the in-NSE handling of
`.fallback` (leave original) and `.drop` (empty content if the filtering entitlement is
granted, else a neutral string).

## Dependencies and blockers

**Blocked** — design content decides what is built:
- DESIGN-N4 D-2 (per-kind copy patterns), D-3 (Time Sensitive for blocking Commands),
  D-5 (thread per instance vs per machine), D-1 (fallback copy, used for comparisons).
- DESIGN-E2 §4.1 (title source when `short_label` missing).
- OQ-N4-3 (apply for `com.apple.developer.usernotifications.filtering`, E-A7): decides
  whether `.drop` can suppress display or must show a neutral line.
- C4-T02.

## Verified starting point

- Apple (accessed 2026-10-06): `interruption-level` values passive/active/time-sensitive/
  critical; time-sensitive breaks through Focus and the user can turn it off; `thread-id`
  groups; `target-content-id` selects the scene (E-A9). Filtering entitlement must be
  applied for and requires `apns-push-type: alert` (E-A7).
- Contract v2 §5: no category/thread/interruption level in the clear; set after decrypt.

## Chosen design (fixed parts)

- Fields come only from the decrypted payload; nothing from the clear wrapper.
- `targetContentIdentifier = "aiur://" + machine_id + "/" + instance key + "/" + target`
  (internal scheme owned by N1-C4-T01 route table; exact string agreed there).
- Category ids per kind: `aiur.command`, `aiur.progress`, `aiur.other` — **no actions** in
  v1 (DESIGN-N6: no answering from the banner).
- Pending parts: copy, thread key, interruption level per kind → filled from DESIGN-N4.

## Implementation steps

Build the mapper and its tests now; only the copy table, thread key and interruption
level per kind wait for DESIGN-N4 D-1/D-2/D-3/D-5 (each lives in one constant table).

1. `AiurClientKit/Sources/Push/Presentation.swift` (PROPOSED): pure
   `func present(_ r: AcceptResult, settings: PresentationSettings) -> PresentationPlan`
   with cases `.content(UNMutableNotificationContent fields)`, `.leaveOriginal`
   (`.fallback`), `.suppress` / `.neutral` (`.drop`, by OQ-N4-3 entitlement flag).
2. `AiurClientKit/Sources/Push/PresentationCopy.swift`: per-kind templates keyed
   `command`, `commandExecutor`, `progress`, `complete`, `prMerged`, `digest`, `other`,
   placeholder strings marked `// DESIGN-N4 D-2 pending`.
3. Fields: `title`, `subtitle`, `body`, `threadIdentifier` (instance per D-5 proposal),
   `categoryIdentifier` (`aiur.command` | `aiur.progress` | `aiur.other`),
   `interruptionLevel` (`.timeSensitive` for `urgency: high` iff D-3 = yes, else
   `.active`), `targetContentIdentifier`, `userInfo["aiur.destination"]`,
   `badge` = `summary.badge` when present (Phase D M3; contract §3).
4. **Lock-screen privacy (Phase D security m9; DESIGN-N4 choice, proposed "hide body
   when locked"):** register the three categories with
   `hiddenPreviewsBodyPlaceholder` = the uniform fallback body and
   `options: [.hiddenPreviewsShowTitle]` off when `settings.hideBodyWhenLocked`;
   the setting defaults to `true` until DESIGN-N4 answers.
5. **Reminder (`attempt: 2`, Phase D M3):** same `threadIdentifier`; the NSE first
   removes the delivered `attempt: 1` notification for the same `stream` (best effort,
   RQ-N4-5) so it replaces rather than stacks.
6. NSE glue in `packages/aiur-mobile/targets/notification-service/` calls `present`.

## Non-happy paths

- Text longer than the OS truncates: rely on OS truncation (caps already enforced by the
  daemon, contract §3).
- Time Sensitive disabled by the user: the OS downgrades; nothing to handle.
- `summary.badge` absent (older daemon) → leave the badge unchanged, never set `0`.
- `summary.title` is agent-authored text (security m3): presented as-is in the
  notification; the in-app Command view (MP-N6) styles it as "from agent".

## Compatibility and rollout

Requires the Time Sensitive capability entitlement
(`com.apple.developer.usernotifications.time-sensitive`) if D-3 = yes (MP-N1-C6-T01 adds
it; V-I5 checks that an NSE-set level is honoured).

## Verification

XCTest `AiurClientKitTests/PresentationTests.swift` (PROPOSED). Test names carry the
DESIGN-N4 decision or §4 state:

| Test | Expected | Must fail without |
| --- | --- | --- |
| `testD2_commandKindMapsToCommandCategory` | `categoryIdentifier == "aiur.command"`, title = `summary.title` | map every kind to `aiur.other` |
| `testS4_unknownKindIsOtherWithNeutralCopy` | `aiur.other`, neutral template | replace with the Command mapping |
| `testS4_fallbackLeavesOriginal` | `.leaveOriginal` | build content from cached data |
| `testD3_blockingIsTimeSensitiveWhenEnabled` / `…ActiveWhenDisabled` | level per flag | constant `.active` |
| `testD5_threadPerInstance` | `threadIdentifier == instance_id` | constant thread |
| `testM9_hideBodyWhenLockedRegistersPlaceholder` | categories carry `hiddenPreviewsBodyPlaceholder` = fallback body | omit the placeholder |
| `testM3_badgeFromPayload` / `testM3_missingBadgeLeavesBadgeUnset` | badge = 3 / `nil` | default badge to `0` |
| `testDestinationKeyIsAiurDestination` | `userInfo["aiur.destination"]` equals the payload destination JSON | another key |

Command (macOS): `xcodebuild test -scheme AiurClientKit -destination 'platform=iOS
Simulator,name=iPhone 16,OS=latest' -only-testing:AiurClientKitTests/PresentationTests`.
Device: V-I1, V-I5 (Focus/Time Sensitive), V-LS1 (lock screen), V-R5 (reminder replaces)
in C7.

## Completion and handoff

- [ ] DESIGN-N4 D-1/D-2/D-3/D-5 and lock-screen answers implemented verbatim in the copy
  table; screenshots in C7 report.
- Docs: `website/docs-app/guide/` notifications page (lock-screen privacy, Time Sensitive).
- Dependents: MP-N4-C7, MP-N6-C2.
