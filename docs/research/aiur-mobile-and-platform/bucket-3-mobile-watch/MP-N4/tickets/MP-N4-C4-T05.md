---
ticket_id: MP-N4-C4-T05
feature_id: MP-N4
chunk_id: MP-N4-C4
bucket: 3-mobile-watch
title: iOS push registration — APNs token, relay handle per machine, push_registration record
status: ready
blocked_by: [DESIGN-N4, MP-N4-C4-T01, MP-N4-C2-T01, N1-C6-T4, MP-N2-C5-T2]
prior_units: []
prior_boundaries: [mobile-app, relay service]
prior_features: [MP-N1, MP-N2]
prior_findings: [contract v2 §7]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C4-T05 — iOS registration

## Identity and outcome

Bucket 3, MP-N4, chunk C4. Build and refresh the device's push registration for each
paired machine:

1. Obtain the APNs device token (`registerForRemoteNotifications`).
2. For each paired machine: `POST <relay_url>/v1/handles {platform: "apns", push_token,
   app_topic: bundle id, environment}` → `{handle, send_secret}` (one handle per machine).
3. Create the per-machine push key (C4-T01) and a fresh 32-byte `device_push_secret`.
4. Build the contract v2 §7 record and hand it to N1-C6-T4, which sends it to the machine
   over the paired channel (pairing contract §4.1 `push` field at claim, or a later update
   call — see CR-N4-3).
5. On token change or rotation: new handle, re-register, then delete the old handle.

Relay URL: the app's build-time default (MP-N4-C2-T06, blocked on OQ-N4-1) or a
user-entered URL in settings (self-build) — the code path is the same.

## Dependencies and blockers

- C4-T01, C2-T01 (relay API), N1-C6-T4 (signed client hand-off), MP-N2-C5-T2 (claim
  accepts `push`). CR-N4-3: MP-N2 needs an endpoint to update `push_registration` after
  pairing (token refresh); requested in CONTRACT-REQUESTS.md.
- DESIGN-N4 gate (permission prompt timing is DESIGN-N4/N2 copy, not this logic).

## Verified starting point

- Contract v2 §7 record fields; pairing contract §4.1 claim body has
  `"push": null | { opaque MP-N4 registration }`.
- Relay handle semantics in C2-T01.

## Chosen design

- `environment`: `sandbox` for debug/TestFlight-development builds, `production` for
  store/TestFlight-production per the build's `aps-environment` entitlement.
- `capabilities` in the record: `{"nse": true, "decrypt_while_locked":
  "after_first_unlock", "watch_forwarding": "unverified"}` until C6-T01 resolves E-B6.
- Permission denied (`UNAuthorizationStatus.denied`): still register (APNs token is
  issued) but set `capabilities.notifications_permitted = false` so the machine can show
  "phone notifications blocked" (plan §7.2) — additive field, recorded in CR-N4-3.
- Secrets (`send_secret`, `device_push_secret`) stored in the keychain (C4-T01 class).

## Implementation steps

1. `AiurClientKit/Sources/Push/Registration.swift` (PROPOSED).
2. Relay client (URLSession, TLS only).
3. Hook into pairing success and token-refresh callbacks.

## Non-happy paths

- Relay unreachable at pairing: pairing still succeeds without `push`; app retries
  registration with backoff and shows the DESIGN-N4 "notifications not set up" state.
- Old handle delete fails: keep retrying in background; harmless (daemon uses the new
  handle).

## Compatibility and rollout

Additive. Rollback: app stops registering; daemon finds no registration → sends nothing.

## Verification

XCTest `RegistrationTests.swift` (PROPOSED) with a URLProtocol stub relay:

| Test | Expected | Must fail without |
| --- | --- | --- |
| `testOneHandlePerMachine` | 2 machines → 2 POSTs, 2 records | share handle |
| `testRecordMatchesContractFields` | exact key set of §7 | drop `device_push_secret` |
| `testTokenRefreshReRegistersAndDeletesOld` | POST new, DELETE old after hand-off | delete first |
| `testDeniedPermissionStillRegistersWithFlag` | `notifications_permitted: false` | skip registration |

Device: V-I1 (end to end) in C7.

## Completion and handoff

- [ ] CR-N4-3 answered by MP-N2 (update endpoint) before merge.
- Dependents: MP-N4-C7, MP-N7 (watch direct registration reuses it).
