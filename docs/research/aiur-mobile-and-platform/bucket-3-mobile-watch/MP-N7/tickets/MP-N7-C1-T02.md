---
ticket_id: MP-N7-C1-T02
feature_id: MP-N7
chunk_id: MP-N7-C1
bucket: 3-mobile-watch
title: iOS watch broker (WatchConnectivity) serving get_command, answer and snapshot in native code
status: blocked
blocked_by: [DESIGN-N7, RQ-TRANSPORT, MP-N2-C10-T01, MP-N7-C1-T01, MP-N1-C2-T01, MP-N1-C2-T05, MP-N1-C3-T04, MP-N6-C1-T01, MP-N6-C1-T03]
prior_units: []
prior_boundaries: ["SD #35 (precedent)"]
prior_features: [MP-N1, MP-N2, MP-N6, MP-E2]
prior_findings: ["framework-evidence S6, S7"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C1-T02 — iOS watch broker

## Identity and outcome

- Bucket 3, MP-N7, chunk C1.
- **User value:** the Apple Watch can show and answer a Command even when the iPhone app
  is suspended, because the iPhone answers watch requests in native code.
- **Deliverable:** `WatchBroker` (Swift, in the `aiur-native` Expo module target of the
  iOS app) that owns the `WCSession`, handles `get_command` and `answer` from the watch,
  replies with `get_command_result`/`answer_result`, and sends `snapshot` through
  `updateApplicationContext`.
- **Non-goals:** voice messages (MP-N7-C4-T04), snapshot *triggers* (MP-N7-C1-T05), the
  late-answer guard logic (MP-N7-C1-T04; this ticket calls it), the watch UI.

## Dependencies and blockers

- DESIGN-N7 gate.
- **RQ-TRANSPORT / MP-N2-C10-T01:** every daemon call the broker makes goes through the
  native signed fetch over the MP-N2 transport; without an HTTPS (or owner-approved
  HTTP-degraded) transport the fetch cannot be made on iOS (ATS; `pairing-and-instance-registry.md` §8.1).
- MP-N7-C1-T01 (models), MP-N1-C2-T01 (Apple core: keychain, `signedFetch`),
  MP-N1-C2-T05 (`AiurNative` module hosting the broker), MP-N1-C3-T04 (snapshot
  projection that produces the `snapshot` body), MP-N6-C1-T01 and T03 (device Command read
  and answer endpoints).
- Concurrent with MP-N7-C1-T03 (Android twin) and MP-N7-C1-T04.

## Verified starting point

- No client code exists at `45a290e3`. The daemon side the broker reaches does not exist
  yet either: device Command read/answer are MP-N6-C1 (PROPOSED
  `GET /api/v1/device/commands/:id`, `POST …/answer`); today the only JSON Command API is the
  supervisor one (`router.ex:84-95`, per `contracts/command-request-and-resolution.md` §9).
- Platform facts (framework-evidence.md S6, accessed 2026-10-06, iOS 9.0+/watchOS 2.0+):
  `sendMessage` from the watch "wakes up the corresponding iOS app in the background";
  `updateApplicationContext` delivers only the newest dictionary; `transferUserInfo` queues.
  WCSession must be activated early in app launch so that a background wake can deliver
  the message (S6 `activate()` requirement); multiple watches are handled through
  `sessionDidBecomeInactive`/`sessionDidDeactivate` and reactivation.
- JS may not be loaded during a background wake (plan.md §3), so the broker must not call
  into React Native.

## Chosen design

```text
WCSessionDelegate (WatchBroker, activated in AppDelegate didFinishLaunching via Expo AppDelegate subscriber)
  didReceiveMessage(_:replyHandler:)  → decode envelope (C1-T01 models)
     get_command  → AiurClientKit.Commands.fetch(instanceId, decisionId) → card → reply
     answer       → LateAnswerGuard.check (C1-T04) → AiurClientKit.Commands.answer(..., client.surface: "watch") → reply
  didReceiveUserInfo(_:)              → answer only (queued path) → same as above, result via transferUserInfo
  sendSnapshot(body)                  → updateApplicationContext(["m": json])
```

- **Answer identity:** the watch generates `idempotency_key` (UUID v4) per submit intent;
  the broker passes it through unchanged and adds `client: {surface: "watch", device_id:
  <phone device_id>}` (`command-request-and-resolution.md` §6). The watch has no
  credential of its own (plan §7; N7-RQ4 deferred).
- **Reply budget:** the broker must reply within the WCSession reply window. Apple does not
  document a fixed limit on the pages cited; the broker therefore uses a 10 s fetch timeout
  and replies `outcome: unreachable` on timeout rather than not replying.
- **Outcome mapping** (server → `answer_result.outcome`): 2xx new → `delivered`;
  `:duplicate` → `duplicate`; 409 `decision_conflict` with winner → `conflict{winner}`;
  guard refusal → `stale`; 401 `device_revoked` → `failed{reason: revoked}`; network →
  `failed{reason: unreachable}`; anything else → `unknown`. Never mapped to `delivered`
  without a 2xx.
- **Revocation:** `device_revoked` from any call makes the broker send a snapshot with that
  machine's `machines[]` entry set to `reachability: revoked` for one snapshot and its instances removed (MP-N7-C1-T01 schema, RC-38), so the watch clears its data
  (plan §8 privacy).
- **Active watch:** only the currently active `WCSession` receives snapshots; on
  `sessionDidDeactivate` the broker calls `activate()` again (S6).

## Implementation steps

1. `modules/aiur-native/ios/WatchBroker.swift` (PROPOSED): singleton, `WCSessionDelegate`,
   `activateIfSupported()` guarded by `WCSession.isSupported()`.
2. Register activation in the Expo module's `AppDelegateSubscriber`
   (`application(_:didFinishLaunchingWithOptions:)`) so activation happens on background
   launches without JS.
3. Message dispatch table keyed by envelope `type`; unknown type → reply
   `failed{reason: "watch_link_type"}`.
4. `get_command` → `AiurClientKit.Commands.fetch`; project to the card (≤ 2 excerpt lines
   from `context.short_summary`/the MP-N6 view model's excerpt field, ≤ 3 options,
   recommended id).
5. `answer` → `LateAnswerGuard` → `AiurClientKit.Commands.answer`.
6. `didReceiveUserInfo` → queued answer path; result returned with `transferUserInfo`.
7. `sendSnapshot(_:)` public to C1-T05.
8. Log only `type`, `outcome`, `instance_id` hash; never bodies.

## Non-happy paths

- Phone app force-quit: iOS will still launch it for `sendMessage`? Not documented for
  force-quit; S41 says the system does not relaunch force-quit apps for background
  pushes. Treated as **UNVERIFIED**, measured in DV-W2b (MP-N7-C6-T01). The watch must
  handle "no reply" (`errorHandler`) as `failed{reason: phone_unavailable}`.
- Machine unreachable: `get_command_result.outcome = unreachable`, card not fabricated.
- Two machines: `instance_id` carries `machine_id`; the broker resolves the machine
  credential from it and never cross-uses tokens.
- Concurrent answers from phone UI and watch for the same Command: each has its own
  `idempotency_key`; the server's first-wins rule decides (D11); the loser gets `conflict`.

## Compatibility and rollout

Ships inside the iOS app; the watch target (MP-N7-C2-T01) is what activates it. If no
watch is paired, `WCSession.isPaired` is false and the broker sends nothing. Rollback:
remove the subscriber registration.

## Verification

Commands (PROPOSED):

```text
xcodebuild test -workspace packages/aiur-mobile/ios/aiur.xcworkspace -scheme aiur -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:aiurTests/WatchBrokerTests
```

`WatchBroker` takes a `WatchSessionProtocol` and a `CommandClient` protocol so tests use
fakes (no real WCSession).

| Test | Expected | Must fail without |
|---|---|---|
| `testGetCommandRepliesWithCard` | fake client returns Command v4 → reply `ok`, 3 options, version 4 | the projection in step 4 |
| `testAnswerAddsWatchSurface` | captured request has `client.surface == "watch"` and the phone `device_id` | the surface injection |
| `testConflictCarriesWinner` | 409 fixture → `conflict` with winner summary | the 409 mapping branch |
| `testUnknownServerErrorIsUnknown` | 500 → `unknown`, not `failed{unreachable}` or `delivered` | the default branch (replace with `delivered` → fails) |
| `testRevokedClearsMachineFromSnapshot` | 401 `device_revoked` → next snapshot lacks that machine | revocation handler |
| `testNoJSBridgeCalls` | broker module has no import of React/ExpoModulesCore JS call APIs (static check script) | — (guard, says so in comment) |
| `testTimeoutRepliesUnreachable` | fake client never returns → reply within 10 s with `unreachable` | the timeout |

Device rows: DV-W2, DV-W4 (MP-N7-C6-T01).

## Completion and handoff

- [ ] Broker handles `get_command`, `answer` (both paths) and `sendSnapshot`.
- [ ] All tests above pass and each fails with its hunk reverted.
- [ ] Docs: none user-facing (watch docs come with MP-N7-C2/C3).
- Dependents: MP-N7-C1-T05, MP-N7-C2-T03, MP-N7-C4-T04, MP-N7-C6-T01.
