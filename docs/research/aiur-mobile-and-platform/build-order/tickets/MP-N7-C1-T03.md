---
ticket_id: MP-N7-C1-T03
feature_id: MP-N7
chunk_id: MP-N7-C1
bucket: 3-mobile-watch
title: Android watch broker (Wearable Data Layer) serving get_command, answer and snapshot in native code
status: blocked
blocked_by: [DESIGN-N7, RQ-TRANSPORT, MP-N2-C10-T01, MP-N7-C1-T01, MP-N1-C2-T02, MP-N1-C2-T05, MP-N1-C3-T04, MP-N6-C1-T01, MP-N6-C1-T03]
prior_units: []
prior_boundaries: ["SD #35 (precedent)"]
prior_features: [MP-N1, MP-N2, MP-N6, MP-E2]
prior_findings: ["framework-evidence S32, S34"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C1-T03 — Android watch broker

## Identity and outcome

- Bucket 3, MP-N7, chunk C1.
- **User value:** a Wear OS watch can fetch and answer a Command through the Android phone
  without the React Native runtime being started.
- **Deliverable:** `AiurWearListenerService` (Kotlin, extends
  `com.google.android.gms.wearable.WearableListenerService`) in the phone app, with
  `MessageClient` request handling for `get_command`/`answer` and a `DataClient` item
  `/aiur/snapshot` for snapshots. Twin of MP-N7-C1-T02; same outcome mapping.
- **Non-goals:** voice (`ChannelClient`, MP-N7-C4-T04), snapshot triggers (C1-T05), UI.

## Dependencies and blockers

- DESIGN-N7; RQ-TRANSPORT / MP-N2-C10-T01 (all daemon calls; Android blocks cleartext by
  default from API 28, framework-evidence S31).
- MP-N7-C1-T01, MP-N1-C2-T02 (Android core: Keystore, `signedFetch`), MP-N1-C2-T05,
  MP-N1-C3-T04, MP-N6-C1-T01/T03.
- Concurrent with C1-T02 and C1-T04.

## Verified starting point

- No Android or Kotlin code in the repo at `45a290e3` (framework-evidence §4: "there is no
  Kotlin in the repo").
- Platform facts (accessed 2026-10-06):
  - Data Layer requires Google Play services and "does not work when the watch is paired
    with an iPhone" (S32, <https://developer.android.com/training/wearables/data/data-layer>, updated 2026-09-28).
  - A data item payload is limited to 100 KB; without `setUrgent()` delivery "may delay
    … up to 30 minutes" (<https://developer.android.com/training/wearables/data/data-items>, updated 2026-09-22).
  - The phone and Wear apps must share the application ID for the Data Layer (MP-N1 plan §3.3).
  - `CapabilityClient` detects whether the companion app is installed on the other node
    (<https://developer.android.com/training/wearables/apps/standalone-apps>, accessed 2026-10-06).

## Chosen design

```text
AiurWearListenerService (manifest: BIND_LISTENER intent filters for MESSAGE_RECEIVED on /aiur/rpc/*)
  RPC service on path prefix "/aiur/rpc" (MessageClient.addRpcService, registered in Application.onCreate)
     get_command → AiurClientCore.Commands.fetch → card bytes
     answer      → LateAnswerGuard.check (C1-T04) → AiurClientCore.Commands.answer(surface="watch")
SnapshotPublisher.publish(body)  → PutDataMapRequest("/aiur/snapshot").setUrgent()
```

- **Request/response:** the watch calls `MessageClient.sendRequest(nodeId, path, data)`
  ("Sends a RPC request …", returns `Task<byte[]>`, the response must arrive "within 1
  minute or task fails"); the phone registers `MessageClient.addRpcService(service,
  "/aiur/rpc")` ("Registers a service to deliver RPC requests to")
  (<https://developers.google.com/android/reference/com/google/android/gms/wearable/MessageClient>,
  accessed 2026-10-06). The watch therefore always gets a reply or a task failure; there is
  no fire-and-forget answer path. Whether a registered RPC service is delivered when the
  phone app process is dead (as `WearableListenerService` messages are) is **UNVERIFIED**:
  the service is registered from `Application.onCreate`, and the listener-service manifest
  entry starts the process on an incoming `MESSAGE_RECEIVED`; DV-W2 (Wear column) measures
  it. If it fails, the fallback is a plain `sendMessage` + reply message correlated by `id`.
- **Snapshot:** a single data item path `/aiur/snapshot`, `setUrgent()` because a delayed
  list shows a misleading state (the doc's stated use case for urgent items). The item
  carries `as_of`; the watch always renders the age.
- **Coroutines:** handlers run on `Dispatchers.IO` with a 10 s timeout; on timeout reply
  `unreachable`.
- **Outcome mapping:** identical table to MP-N7-C1-T02 (shared fixture
  `fixtures/watch-link/outcome-mapping.json` drives both test suites).
- **Revocation:** same rule as iOS: publish a snapshot without the revoked machine.
- **No Wear app installed:** `CapabilityClient.getCapability("aiur_wear_app",
  FILTER_REACHABLE)` empty → `SnapshotPublisher` does nothing (no orphan data items).

## Implementation steps

1. `modules/aiur-native/android/src/main/java/.../wear/AiurWearListenerService.kt` (PROPOSED)
   plus manifest entry with `com.google.android.gms.wearable.MESSAGE_RECEIVED` filter for
   host `*` path prefix `/aiur/`.
2. `WearRpcHandler` with injected `CommandClient` and `Clock` (testable).
3. `SnapshotPublisher` with injected `DataClient` facade.
4. `res/values/wear.xml` declaring capability `aiur_phone_app` (watch side declares
   `aiur_wear_app` in MP-N7-C3-T01).
5. Logging: type, outcome only.

## Non-happy paths

- Phone app process dead: `WearableListenerService` is started by Play services on a
  message (service is bound on demand). Latency is measured in DV-W2 (Wear column).
- Play services missing (de-Googled phone): Data Layer unavailable → the Wear app shows
  "Needs phone" (C3); the phone settings screen marks the watch affordance
  `unavailable{reason: play_services_missing}`.
- iPhone-paired Wear watch: out of scope (S32); no code path.

## Compatibility and rollout

Ships in the Android app. Inert when no Wear app is reachable. Rollback: remove the
manifest service entry.

## Verification

```text
packages/aiur-mobile/android/gradlew -p packages/aiur-mobile/android :aiur-native:testDebugUnitTest --tests '*WearRpcHandlerTest' --tests '*SnapshotPublisherTest'
```

(PROPOSED paths; Robolectric not required: handlers are pure Kotlin with fakes.)

| Test | Expected | Must fail without |
|---|---|---|
| `getCommandReturnsCard` | card with version and ≤3 options | projection |
| `answerSetsWatchSurface` | captured request `client.surface == "watch"` | surface injection |
| `outcomeMappingMatchesSharedFixture` | every row of `outcome-mapping.json` matches | the mapping table (change `unknown`→`delivered` → fails) |
| `timeoutRepliesUnreachable` | fake never completes → reply `unreachable` in ≤ 10 s (virtual time) | the timeout |
| `snapshotIsUrgent` | the `PutDataRequest` has `isUrgent == true` | `setUrgent()` call |
| `noPublishWithoutWearApp` | empty capability → no `putDataItem` | the capability check |

Device rows: DV-W2 (Wear), DV-W4 (Wear) in MP-N7-C6-T02.

## Completion and handoff

- [ ] Handler, publisher and manifest entries; tests pass and fail with hunks reverted.
- [ ] Docs: none user-facing.
- Dependents: MP-N7-C1-T05, MP-N7-C3-T03, MP-N7-C4-T04, MP-N7-C6-T02.
