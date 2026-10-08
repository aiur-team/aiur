---
ticket_id: MP-N6-C5-T03
feature_id: MP-N6
chunk_id: MP-N6-C5
bucket: 3-mobile-watch
title: "Open on phone" hand-off from the watch card to the same Command
status: blocked
blocked_by: [DESIGN-N7, DESIGN-N6, MP-N6-C5-T01, MP-N6-C2-T01, MP-N7-C1-T02, MP-N7-C1-T03]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N7]
prior_findings: [E-B5]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C5-T03 — Open on phone

## Identity and outcome

Bucket 3, MP-N6, chunk C5. "Open on phone" sends the Command's destination (contract v2
§3.1 shape) over the MP-N7 watch link; the phone runs the C2-T01 resolver and opens the
Command screen (or shows a notification prompting the user to pick up the phone, per
DESIGN-N7 — watchOS cannot foreground the iPhone app silently).

## Dependencies and blockers

**Blocked** on DESIGN-N7 (hand-off presentation), MP-N7 watch link (brokers MP-N7-C1-T02 iOS and
MP-N7-C1-T03 Android), C5-T01.

## Verified starting point

E-B5; contract v2 §3.1.

## Chosen design (fixed parts)

- The hand-off carries only the destination (no Command content): message
  `open_on_phone{v: 1, destination, intent?: "answer" | "converse"}` on the MP-N7 watch link
  (iOS `sendMessage`, Android `MessageClient`), added to the MP-N7-C1-T01 schema by a
  schema row request (below).
- Phone side: the brokers (MP-N7-C1-T02/T03) call `handleOpenOnPhone(msg)` in
  `packages/aiur-mobile/src/landing/openOnPhone.ts`, which runs the C2-T01 resolver and
  `landOn` (C2-T02). iOS cannot foreground the app silently, so when the app is not active
  the phone posts a local notification "Continue on iPhone" whose tap carries the same
  destination (presentation per DESIGN-N7, design-pending).
- The watch waits at most 5 s for the phone's ack; no ack → "Phone not reachable".

## Implementation steps

1. `src/landing/openOnPhone.ts` (phone) and its local-notification fallback.
2. Watch buttons: `OpenOnPhoneAction.swift` / `OpenOnPhoneAction.kt` sending the message.
3. Add a valid and an invalid `open_on_phone` case to `fixtures/watch-link/valid|invalid/`
   (schema row owned by MP-N7-C1-T01; handed off).
4. Docs: none beyond the MP-N7 watch section of `website/docs-app/guide/mobile.md`,
   because "Open on phone" is one button on the documented watch card.

## Non-happy paths

- Phone unreachable → watch shows "Phone not reachable" after 5 s.
- Destination for a machine the phone is not paired with → C2-T01 "Not paired" (S12).
- App locked (S18) → the local notification still opens it after unlock.

## Compatibility and rollout

watchOS 10 / Wear OS per MP-N7.

## Verification

```text
npm --prefix packages/aiur-mobile test -- test/landing/openOnPhone.test.ts
xcodebuild test -workspace packages/aiur-mobile/ios/aiur.xcworkspace -scheme AiurWatch -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)' -only-testing:AiurWatchTests/OpenOnPhoneActionTests
packages/aiur-mobile/wear/gradlew -p packages/aiur-mobile/wear :app:testDebugUnitTest --tests '*OpenOnPhoneActionTest'
```

| Test | Expected | Must fail without |
| --- | --- | --- |
| `payloadIsDestinationOnly` | message validates against the schema and has no `question`/`context`/`options` | the content filter |
| `phoneRunsResolverAndLands` | `resolveDestination` + `landOn` called with the payload | the hand-off wiring |
| `backgroundPostsLocalNotification` | app not active → local notification with the same destination | the iOS fallback |
| `noAckShowsPhoneNotReachable` (watch, both platforms) | 5 s without ack → "Phone not reachable" | the timeout |

Device: V-W2 extension (tap "Open on phone" with the phone locked and unlocked).

## Completion and handoff

- [ ] Each test fails with its hunk reverted in a worktree.
- Dependents: none.
