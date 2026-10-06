---
ticket_id: MP-N7-C3-T01
feature_id: MP-N7
chunk_id: MP-N7-C3
bucket: 3-mobile-watch
title: Wear OS Gradle project (non-standalone, Compose for Wear) with Data Layer client and CI build
status: blocked
blocked_by: [DESIGN-N7, MP-N1-C1-T01, MP-N1-C1-T02, MP-N1-C2-T02, MP-N7-C1-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-N1]
prior_findings: ["RC-17", "framework-evidence S32, S34, S37"]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N7-C3-T01 — Wear OS project and phone link

## Identity and outcome

- Bucket 3, MP-N7, chunk C3 (Wear OS app). Merges candidate tickets N7-C3-T1 (project)
  and N7-C3-T4 (CI) from chunks.md: CI for a new module is part of making it exist.
- **User value:** a Wear OS app installs alongside the Android app and can talk to it.
- **Deliverable:** Gradle project `packages/aiur-mobile/wear/` (RC-17) producing a
  non-standalone Wear app with the **same application ID** as the phone app, Compose for
  Wear OS Material 3, a `PhoneLink` (Data Layer: `DataClient` listener for
  `/aiur/snapshot`, `MessageClient.sendRequest` for `/aiur/rpc`), a stored last snapshot,
  a placeholder screen, and a CI job building and unit-testing it.
- **Non-goals:** screens (C3-T02/T03), notifications (C3-T04).

## Dependencies and blockers

DESIGN-N7 (D-N7-6: whether Wear ships in v1 changes scheduling only), MP-N1-C1-T01/T02,
MP-N1-C2-T02 (Android core models module to include), MP-N7-C1-T01.

## Verified starting point

- No Android/Kotlin code at `45a290e3`; CI precedent `.github/workflows/streamdeck-package.yml`
  (path-filtered PR builds).
- Facts (accessed 2026-10-06):
  - `com.google.android.wearable.standalone` `false` = non-standalone; "Non-standalone apps
    aren't available to users on untethered devices"; "watch apps should detect and prompt
    users to install the phone app if needed"; use `CapabilityClient`; new apps target API
    34+ (<https://developer.android.com/training/wearables/apps/standalone-apps>).
  - Compose for Wear OS 1.7.0 stable (2026-09-23), Material 3 for Wear supersedes
    `compose-material` (S37).
  - Data Layer requires Play services and does not work with iPhone pairing (S32).
- Wear OS version: the slot uses **Wear OS 5 or later** (DV matrix). Wear OS 5 is based on
  Android 14 (API 34) — consistent with the API 34 target requirement above.

## Chosen design

```text
packages/aiur-mobile/wear/
  settings.gradle.kts  → includeBuild("../native/android-core") for models
  app/build.gradle.kts → applicationId = <phone app id>, minSdk 34, targetSdk 35+, compose-material3 for Wear
  app/src/main/AndroidManifest.xml → <uses-feature android:name="android.hardware.type.watch"/>,
                                       meta-data standalone=false
  app/src/main/res/values/wear.xml → capability "aiur_wear_app"
  app/src/main/java/.../PhoneLink.kt, SnapshotRepository.kt (DataStore file), MainActivity.kt
```

- `PhoneLink.phoneReachable` = `CapabilityClient` reports a reachable node with
  `aiur_phone_app`; updated on capability change.
- `sendAnswer` uses `MessageClient.sendRequest` (response within 1 minute or failure,
  MessageClient reference, accessed 2026-10-06). Failure → `notConfirmed`; there is no
  queued path on Wear (no `transferUserInfo` equivalent is used; plan §4).
- Phone app missing: show "Install aiur on your phone" with
  `RemoteActivityHelper.startRemoteActivity` to the Play listing (doc above).

## Implementation steps

1. Create the Gradle project with version catalog pins (Compose for Wear 1.7.x,
   play-services-wearable current at implementation, Kotlin per MP-N1-C2-T02).
2. `PhoneLink`, `SnapshotRepository` with fakes for tests.
3. Placeholder screen.
4. Add job `wear` to `.github/workflows/mobile-package.yml` (MP-N1-C1-T02): path filter
   `packages/aiur-mobile/wear/**`, `native/android-core/**`; `./gradlew assembleDebug test`
   on `ubuntu-latest`.

## Non-happy paths

- iPhone-paired Wear watch: `PhoneTypeHelper.getPhoneDeviceType` returns
  `DEVICE_TYPE_IOS` → screen "aiur on Wear OS needs an Android phone" (doc above lists this API).
- Play services missing → same "Needs phone" state with reason.

## Compatibility and rollout

New module; ships with the Android app per MP-N1-C8 (Play internal testing). Rollback:
remove the job and module.

## Verification

```text
packages/aiur-mobile/wear/gradlew -p packages/aiur-mobile/wear :app:testDebugUnitTest
packages/aiur-mobile/wear/gradlew -p packages/aiur-mobile/wear :app:assembleDebug
```

| Test | Expected | Must fail without |
|---|---|---|
| `PhoneLinkTest.snapshotItemDecodedAndStored` | fixture item → repository updated | decode/store |
| `PhoneLinkTest.requestFailureIsNotConfirmed` | failing task → `notConfirmed` | failure branch (map to delivered → fails) |
| `ManifestTest.standaloneFalse` | merged manifest meta-data value `false` | the meta-data line |
| `PhoneTypeTest.iosPhoneShowsUnsupported` | IOS type → unsupported screen state | the branch |
| CI | job green on a PR touching `wear/` | path filter |

## Completion and handoff

- [ ] Module builds and tests in CI; installs on a Wear OS 5+ emulator and device (C6-T02).
- [ ] Docs: Wear OS install note in the mobile guide page (same PR).
- Dependents: MP-N7-C3-T02..T05, MP-N7-C4, MP-N7-C5-T02.
