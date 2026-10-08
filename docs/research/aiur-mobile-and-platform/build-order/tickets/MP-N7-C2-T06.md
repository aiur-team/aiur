---
ticket_id: MP-N7-C2-T06
feature_id: MP-N7
chunk_id: MP-N7-C2
bucket: 3-mobile-watch
title: Per-Command option buttons in the Apple Watch long-look (conditional on DV-W10)
status: blocked
blocked_by: [DESIGN-N7, DESIGN-N4 D-7, DESIGN-N6, MP-N7-C2-T04, MP-N7-C6-T01 (DV-W1, DV-W10 results)]
prior_units: []
prior_boundaries: []
prior_features: [MP-N4, MP-N6]
prior_findings: ["N7-RQ1 resolved for the API; forwarded-content question tied to E-B6"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C2-T06 — Dynamic option actions on the watch notification

## Identity and outcome

- Bucket 3, MP-N7, chunk C2. **Conditional ticket**: executed only if DV-W10 passes and
  DESIGN-N7 wants answering from the notification itself.
- **User value:** answer a blocker straight from the wrist notification (one tap fewer).
- **Deliverable:** in `CommandNotificationController.didReceive(_:)`, set
  `notificationActions` to one `UNNotificationAction` per option (≤ 3, labels from the
  decrypted payload), and handle the action by sending `answer` through `PhoneLink`
  with the payload's `version` as `expected_version`.
- **Non-goals:** iPhone-side banner action buttons (MP-N4/N6 decide those).

## Dependencies and blockers

- **DESIGN-N4 D-7** (owner of payload content: whether option labels travel in the push
  payload; recommended there "no labels, the card opens", which means this ticket is **not
  built**). DESIGN-N7 D-N7-9 is a link to D-7 (review G-7, X7). DESIGN-N7 / DESIGN-N6 decide
  whether answering from the notification is wanted at all.
- MP-N7-C2-T04; **DV-W1 and DV-W10 results** (MP-N7-C6-T01): the forwarded notification must
  carry the decrypted options in `userInfo`. If DV-W10 fails, this ticket is closed as
  "not feasible on forwarded notifications" and the default action (C2-T04) remains.
- The notification payload must carry option ids/labels and the Command `version`
  (request to MP-N4, CONTRACT-REQUESTS.md item 3); without `version` this ticket cannot
  build a safe answer.

## Verified starting point

- **N7-RQ1 (API part), resolved:** `WKUserNotificationInterfaceController.notificationActions`:
  "Use this array to dynamically update the list of actions associated with a notification.
  You can only change this property during the `didReceive(_:)` method." Availability
  **watchOS 5.0+**
  (<https://developer.apple.com/documentation/watchkit/wkusernotificationinterfacecontroller/notificationactions>,
  read via the documentation JSON on 2026-10-06). The SwiftUI `WKUserNotificationHostingController` used in
  C2-T04 is expected to inherit this property from `WKUserNotificationInterfaceController`
  (**UNVERIFIED** here: confirm against the pinned watchOS SDK headers in step 1); whether its
  `notificationActions` behaves identically on forwarded notifications is part of DV-W10.
- iOS category registration is static at launch (MP-N4 E-A8), which is why the phone
  banner cannot carry per-Command option titles without a content extension.

## Chosen design

- Action identifiers `aiur.opt.<option_id>`; options `[]` (no `.foreground`, no
  `.authenticationRequired` is set because the watch is unlocked on wrist for forwarding).
- On action: build `answer{instance_id, decision_id, expected_version: payload.version,
  idempotency_key: UUID, created_at: now, option_id}` and call
  `PhoneLink.sendAnswer`; the result is shown as a local notification
  ("Sent" / "Not confirmed — open aiur on iPhone") because the notification UI is gone.
- The late-answer guard (C1-T04) applies on the phone as for every answer.

## Implementation steps

1. Extend `CommandNotificationController` (`didReceive`) to read `aiur_options` and
   `aiur_version` from `userInfo`.
2. Action handler in the notification center delegate.
3. Unit tests for action building; DV-W10 device proof.

## Non-happy paths

- Missing options/version in payload → no actions (default open only).
- Phone unreachable → `transferUserInfo` queued → result notification "Not confirmed";
  never "Sent".
- Conflict → result notification names the winner surface.

## Compatibility and rollout

Behind `WatchFeatures.notificationActions` flag, default off until DV-W10 passes.

## Verification

```text
xcodebuild test -workspace packages/aiur-mobile/ios/aiur.xcworkspace -scheme AiurWatch -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)' -only-testing:AiurWatchTests/NotificationActionBuilderTests
```

| Test | Expected | Must fail without |
|---|---|---|
| `testThreeOptionsBecomeThreeActions` | 3 actions with ids `aiur.opt.*` | builder |
| `testNoVersionNoActions` | payload without version → `[]` | the version requirement |
| `testQueuedResultSaysNotConfirmed` | queued → "Not confirmed" | result mapping |

Device: DV-W10.

## Completion and handoff

- [ ] Flag on only after DV-W10 passes on watchOS 26.x; otherwise ticket closed with the DV record.
- Dependents: none.
