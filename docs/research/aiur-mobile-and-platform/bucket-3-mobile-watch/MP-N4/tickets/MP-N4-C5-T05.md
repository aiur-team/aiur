---
ticket_id: MP-N4-C5-T05
feature_id: MP-N4
chunk_id: MP-N4-C5
bucket: 3-mobile-watch
title: Android push registration — FCM token, relay handle per machine, token refresh
status: ready
blocked_by: [DESIGN-N4, MP-N4-C5-T01, MP-N4-C2-T01, N1-C6-T4, MP-N2-C5-T2]
prior_units: []
prior_boundaries: [mobile-app, relay service]
prior_features: [MP-N1, MP-N2]
prior_findings: [contract v2 §7]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C5-T05 — Android registration

## Identity and outcome

Bucket 3, MP-N4, chunk C5. Same as C4-T05 for Android: get the FCM registration token
(`FirebaseMessaging.getInstance().token`), create one relay handle per paired machine
(`platform: "fcm"`, `app_topic` = the Firebase app id the relay allowlists), create the
per-machine keyset (C5-T01) and `device_push_secret`, build the contract v2 §7 record
(`capabilities: {"nse": false, "decrypt_while_locked": "after_first_unlock" |
"unverified_before_first_unlock"}`), hand it to N1-C6-T4. `onNewToken` → re-register and
delete old handles.

## Dependencies and blockers

- C5-T01, C2-T01, N1-C6-T4, MP-N2-C5-T2; CR-N4-3 (MP-N2 update endpoint for
  `push_registration` after pairing). DESIGN-N4 gate (no content dependency).

## Verified starting point

- Contract v2 §7; relay API in C2-T01; FCM token refresh is delivered via
  `FirebaseMessagingService.onNewToken` (Firebase receive-messages page,
  firebase.google.com/docs/cloud-messaging/android/receive-messages, accessed 2026-10-06 —
  implementer re-reads the current page while adding the dependency).

## Chosen design

Mirror C4-T05: secrets in the Keystore-wrapped encrypted prefs; one handle per machine;
`notifications_permitted` flag from `POST_NOTIFICATIONS` state.

## Implementation steps

`aiur-client-core/src/main/kotlin/push/Registration.kt` (PROPOSED); hook pairing success
and `onNewToken`.

## Non-happy paths

Relay unreachable → pairing succeeds without push, background retry; Google Play services
missing (de-Googled device) → registration impossible, app shows the DESIGN-N4
"notifications unavailable on this phone" state (UnifiedPush is RQ-N4-6, deferred).

## Compatibility and rollout

Additive; rollback stops registration.

## Verification

JUnit with MockWebServer relay: `oneHandlePerMachine`, `recordMatchesContractFields`,
`onNewTokenReRegistersThenDeletesOld` (must fail if delete precedes hand-off),
`noPlayServicesReportsUnavailable`. Device: V-A1 in C7.

## Completion and handoff

- [ ] CR-N4-3 answered. Dependents: C7, MP-N7 (Wear OS direct, if adopted).
