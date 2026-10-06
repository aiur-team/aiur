---
ticket_id: MP-N7-C2-T04
feature_id: MP-N7
chunk_id: MP-N7-C2
bucket: 3-mobile-watch
title: Apple Watch notification open routing to the Command card (forwarded iPhone notifications)
status: blocked
blocked_by: [DESIGN-N7, DESIGN-N4, MP-N7-C2-T03, MP-N1-C6-T01, MP-N4-C6-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-N4, MP-N1, MP-N6]
prior_findings: ["MP-N4 E-B1 forwarding rules; E-B6 UNVERIFIED decrypted forwarding"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C2-T04 — Notification open routing on Apple Watch

## Identity and outcome

- Bucket 3, MP-N7, chunk C2.
- **User value:** tapping a blocker notification on the wrist opens that Command's card,
  in at most two taps from the notification (plan AC3), with no microphone activity.
- **Deliverable:** a `WKNotificationScene` for category `AIUR_COMMAND` with a static
  long-look (no custom actions in this ticket), and the watch app's notification
  response handler that routes the default action to `CommandCardView(instanceId,
  decisionId)`.
- **Non-goals:** dynamic per-Command action buttons (MP-N7-C2-T06, conditional); the
  watch's own APNs registration (N7-RQ4, deferred).

## Dependencies and blockers

- DESIGN-N7 (long-look screen 8), DESIGN-N4 (notification text).
- MP-N7-C2-T03, MP-N1-C6-T01 (iOS NSE sets `categoryIdentifier = "AIUR_COMMAND"` and puts
  the decrypted destination `{machine_id, instance_id, decision_id}` in `userInfo` under
  key `aiur_dest`), MP-N4-C6-T01 (forwarding verification decision).

## Verified starting point

- No client code at `45a290e3`.
- Forwarding (MP-N4 platform-evidence E-B1, accessed 2026-10-06,
  <https://developer.apple.com/documentation/watchos-apps/taking-advantage-of-notification-forwarding>):
  iPhone unlocked and screen on → phone; else watch on wrist and unlocked → watch; else
  iPhone. Background pushes are never forwarded.
- Whether the forwarded copy carries the NSE-modified content is **UNVERIFIED** (E-B6;
  DV-W1). This ticket's routing reads `userInfo.aiur_dest`; if DV-W1 shows the forwarded
  copy carries the original (encrypted) payload instead, the watch cannot route and falls
  back to opening the instance list with "Open on iPhone for details" (decision recorded in
  MP-N4-C6-T01).
- Long-look scenes are bound to a category: "When the system receives a notification with a
  matching category, it displays a dynamic view specified by the notification controller"
  (<https://developer.apple.com/documentation/watchos-apps/customizing-your-long-look-interface>,
  accessed 2026-10-06).

## Chosen design

- `AiurWatchApp` declares `WKNotificationScene(controller: CommandNotificationController.self,
  category: "AIUR_COMMAND")`. The controller's view shows title/body as delivered (no
  extra fetch inside the notification).
- `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:)` on the watch:
  default action → parse `aiur_dest`; valid → push `InstanceDetail → CommandCard`; missing
  or invalid → instance list with banner "Open on iPhone for details".
- The handler never starts audio, never opens the mic sheet (brief N6 rule).
- `threadIdentifier` grouping is set by the iPhone NSE (MP-N4); nothing to do here.

## Implementation steps

1. `CommandNotificationController.swift` (`WKUserNotificationHostingController<…>`),
   `NotificationRouter.swift` (pure parse of `userInfo` → route).
2. Register the scene; set the notification center delegate in `applicationDidFinishLaunching`.
3. Tests for the router; UI test for routing.

## Non-happy paths

- Malformed or absent `aiur_dest` → list + banner; never a guessed Command.
- Command resolved meanwhile → card shows resolved state (C2-T03 refetch).
- Phone unreachable when opening → card in `needsPhone` with the notification's text.

## Compatibility and rollout

Requires the iOS NSE category name to be stable (`AIUR_COMMAND`); request recorded for
MP-N1-C6-T01 / MP-N4 in CONTRACT-REQUESTS.md item 3.

## Verification

```text
xcodebuild test -workspace packages/aiur-mobile/ios/aiur.xcworkspace -scheme AiurWatch -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)' -only-testing:AiurWatchTests/NotificationRouterTests
```

Simulator notification test: `xcrun simctl push <watch-sim-udid> <watch bundle id> fixtures/watch-link/apns-forwarded-command.apns`
(a `.apns` file with `aps.category = AIUR_COMMAND` and `aiur_dest`).

| Test | Expected | Must fail without |
|---|---|---|
| `testValidDestRoutesToCard` | route = card(instance, decision) | parser |
| `testMissingDestFallsBackToList` | route = list + banner | fallback (replace with first open Command → fails) |
| `testNoAudioSessionOnOpen` | `AVAudioSession` category untouched after routing (spy) | — (guard for brief N6; commented) |

Device rows: DV-W1, DV-W1b (routing), DV-W11 (MP-N7-C6-T01).

## Completion and handoff

- [ ] Routing works on simulator push and on device (DV-W1b).
- Dependents: MP-N7-C2-T06, MP-N7-C6-T01.
