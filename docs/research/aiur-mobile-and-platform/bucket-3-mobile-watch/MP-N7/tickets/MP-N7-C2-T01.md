---
ticket_id: MP-N7-C2-T01
feature_id: MP-N7
chunk_id: MP-N7-C2
bucket: 3-mobile-watch
title: watchOS SwiftUI target via config plugin, WCSession client, shared models only
status: blocked
blocked_by: [DESIGN-N7, MP-N1-C1-T01, MP-N1-C1-T02, MP-N1-C1-T03, MP-N1-C2-T01, MP-N7-C1-T01, N1-RQ3]
prior_units: []
prior_boundaries: []
prior_features: [MP-N1]
prior_findings: ["RC-17: watch apps live inside packages/aiur-mobile", "framework-evidence S13, S22"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C2-T01 — watchOS target and watch-side session client

## Identity and outcome

- Bucket 3, MP-N7, chunk C2 (watchOS app).
- **User value:** an Apple Watch app installs with the iOS app and can talk to it.
- **Deliverable:** a single-target SwiftUI watchOS app at
  `packages/aiur-mobile/targets/watch/` (RC-17), added to the generated Xcode project by
  the Apple-targets config plugin, embedded in the iOS app, linking only the **models**
  part of `AiurClientKit` (no keychain, signing or decryption). It includes
  `PhoneLink`, the watch-side `WCSessionDelegate` that decodes `snapshot`, sends
  `get_command`/`answer`, and stores the last snapshot on disk for the age display.
  A placeholder root view shows "Waiting for iPhone" (real screens are C2-T02/T03).
- **Non-goals:** screens, notifications, voice.

## Dependencies and blockers

- DESIGN-N7 (app name/icon on the watch reuse DESIGN-N1 D-N1-4).
- MP-N1-C1-T01/T02 (Expo app and CI), MP-N1-C1-T03 (expo-apple-targets entitlements and watch target plumbing), MP-N1-C2-T01 (Apple core package to link),
  MP-N7-C1-T01 (models).
- **N1-RQ3** (MP-N1 research: does a watch target plus an NSE target survive
  `expo prebuild --clean` with entitlements intact). If N1-RQ3 fails, this ticket keeps the
  same files but adds them with a committed Xcode project fragment instead; that switch is
  MP-N1's decision, not this ticket's.

## Verified starting point

- Nothing exists at `45a290e3`.
- Facts (accessed 2026-10-06): new watch apps are a single SwiftUI target; WatchKit
  storyboards are deprecated in watchOS 7+ (S13, Xcode 14 release notes).
  `expo-apple-targets` supports a `watch` target type and keeps targets outside the
  generated `/ios` folder; it needs Expo SDK 53+ and Xcode 16 (S22, community source,
  <https://github.com/EvanBacon/expo-apple-targets>).
- Dependent vs independent: "Independent watchOS apps can't rely on the WatchConnectivity
  framework to transfer data" (S8). This app is **dependent** (D-N7-1 recommendation), so it
  sets `WKRunsIndependentlyOfCompanionApp = NO` and `WKCompanionAppBundleIdentifier` to the
  iOS bundle ID.
- Current watchOS: 26.6 (S14). Minimum: DESIGN-N1 D-N1-3 proposes iOS 17+; the matching
  watchOS minimum is **watchOS 10** (the watchOS release paired with iOS 17), which is also
  the CryptoKit HPKE floor recorded by MP-N4 (E-C1) should a later standalone path need it.

## Chosen design

```text
targets/watch/
  expo-target.config.js     # type: "watch", deploymentTarget "10.0", bundle suffix ".watchkitapp"
  AiurWatchApp.swift        # @main App
  PhoneLink.swift           # WCSessionDelegate; activate on init; publishes @Observable state
  SnapshotStore.swift       # last snapshot JSON in the app container, with received_at
  Info.plist                # WKCompanionAppBundleIdentifier, WKRunsIndependentlyOfCompanionApp=false
```

`PhoneLink` state: `{snapshot: Snapshot?, receivedAt: Date?, phoneReachable: Bool}` where
`phoneReachable = WCSession.default.isReachable`. API:
`fetchCommand(instanceId, decisionId) async -> GetCommandResult`,
`sendAnswer(Answer) async -> AnswerResult` (uses `sendMessage` with reply when reachable,
else `transferUserInfo` and returns `.queued`; plan §4 says no automatic replay).

The watch target links `AiurClientKit`'s `WatchLink` models product only. A test asserts
that no `Security`/`CryptoKit` symbol from the core is reachable from the watch target
(the watch holds no credentials, plan §8).

## Implementation steps

1. Add the target config and sources above; add the target to the CI workflow's iOS build
   (`xcodebuild build -scheme AiurWatch -destination 'generic/platform=watchOS Simulator'`).
2. Implement `PhoneLink` with an injectable `WatchSessionProtocol` (fake for tests).
3. Persist the last snapshot (overwrite) so the app shows data with its age after relaunch.
4. Placeholder root view.

## Non-happy paths

- `WCSession.isSupported()` is always true on watchOS; activation failure → state
  `phoneReachable = false`, root shows "Needs iPhone nearby".
- Snapshot decode failure (version skew) → keep the previous snapshot, show "Update the
  watch app" if `v` major differs.
- Unpaired (machine removed) snapshot → `SnapshotStore` deletes stored rows for that machine.

## Compatibility and rollout

New target, embedded in the iOS app. Distribution follows MP-N1-C8 (internal TestFlight
first). Rollback: remove the target config; the iOS app is unaffected.

## Verification

```text
xcodebuild test -workspace packages/aiur-mobile/ios/aiur.xcworkspace -scheme AiurWatch -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)'
npx expo prebuild --clean --platform ios && xcodebuild -list -workspace packages/aiur-mobile/ios/aiur.xcworkspace   # must list AiurWatch
```

| Test | Expected | Must fail without |
|---|---|---|
| `PhoneLinkTests.testSnapshotDecodedAndStored` | fixture snapshot → state + file written | decode/store code |
| `testUnreachableUsesTransferUserInfo` | fake `isReachable=false` → `transferUserInfo` called, result `.queued` | the fallback branch |
| `testNoAutomaticReplay` | reply error → no second send | — (guard; commented as future-regression guard) |
| `testMachineRemovalPurgesRows` | snapshot without machine X → stored rows for X gone | purge |
| `WatchTargetLinkageTests.testNoCredentialSymbols` | static check of linked products | the products list in target config |
| CI prebuild check | `AiurWatch` scheme exists after `prebuild --clean` | the config plugin entry |

Device row: DV-W9 (MP-N7-C6-T01) guards against designs that pass only on the simulator.

## Completion and handoff

- [ ] Target builds in CI; installs with the iOS app on a device (DV-W smoke in C6-T01).
- [ ] Docs: the mobile guide page added by MP-N1-C1 (docs ticket) gains a "Apple Watch" install note
  (`website/docs-app/guide/`, same PR).
- Dependents: MP-N7-C2-T02..T06, MP-N7-C4, MP-N7-C5-T01.
