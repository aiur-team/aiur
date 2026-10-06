---
ticket_id: MP-N4-C5-T02
feature_id: MP-N4
chunk_id: MP-N4-C5
bucket: 3-mobile-watch
title: Android acceptance pipeline in onMessageReceived — decrypt, verify, dedup, always post
status: ready
blocked_by: [DESIGN-N4, MP-N4-C5-T01, MP-N4-C1-T04, MP-N1-C2-T03, MP-N1-C6-T01]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N1]
prior_findings: [E-F1, E-F4, E-F5, E-F6]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C5-T02 — Android acceptance pipeline

## Identity and outcome

Bucket 3, MP-N4, chunk C5. The Kotlin equivalent of C4-T02: a pure
`accept(data: Map<String,String>, now, keys, seen): AcceptResult` in `aiur-client-core`
(Tink `HybridDecrypt.decrypt(sealed, info)`, Ed25519 verify, frame/`v`/kid/machine/
expiry/`nid`/stream checks per contract v2 §4–§6), called from the
`FirebaseMessagingService.onMessageReceived`, which this ticket creates (the Phase B candidate
N1-C6-T02 folded into MP-N4-C5; MP-N1-C6-T01 keeps only the FCM build plumbing). Rule from contract §5:
**every verified `urgency: high` payload results in a posted notification**; every
failure posts the uniform fallback (data messages are never shown by the system, so the
app must post something for high priority, E-F4).

## Dependencies and blockers

- C5-T01, C1-T04 vectors, N1-C2-T03 (shared decrypt helper), MP-N1-C6-T01 (FCM build plumbing the service class needs).
- DESIGN-N4 gate; logic fixed by the contract. Notification copy/channels are C5-T03.

## Verified starting point

- E-F1: data messages are handled by the app; E-F4: high priority "should result in user
  interaction", FCM may deprioritize otherwise; E-F5: `onMessageReceived` short window,
  handle within ~10 s, WorkManager for longer work (firebase.google.com, updated
  2026-10-06).
- E-C5: Tink `contextInfo` = HPKE `info`.

## Chosen design

- Budget 2 s, CPU only; posting uses a pre-created channel (C5-T03 creates channels at
  app start; until DESIGN-N4 copy exists, a single placeholder channel is used in tests).
- `SeenStore` in credential-encrypted SharedPreferences (last 512 `nid`s, per-stream
  `seq`).
- Notification tag = `nid` (enables cancel-by-tag in C5-T04).
- WorkManager only for non-display bookkeeping (pruning SeenStore).

## Implementation steps

1. `aiur-client-core/src/main/kotlin/push/Acceptance.kt` (PROPOSED).
2. Service glue (`AiurMessagingService`, PROPOSED) calls it and posts.
3. Vector-driven JUnit.

## Non-happy paths

- Before first unlock (RQ-N4-4, settled from Firebase's Direct Boot page): the service is
  **not** marked `directBootAware`, so it never runs before first unlock (a direct-boot-
  aware service would crash reading CE storage). No pre-unlock branch is needed; the
  `Locked` result stays as a defensive fallback. V-A3 records timing.
- **Local key loss (Phase D M6):** `PushKeyStore` returns `KeysUnavailable` →
  `Fallback(KEYS_UNAVAILABLE)` with `mustPost = true` for **every** priority: the uniform
  fallback is posted, and tapping it opens the app on "Open aiur to re-pair". Silent
  `Drop` is reserved for verification failures (bad signature, unknown `kid`, seen,
  expired, superseded) on a keyset that was readable.
- Decrypt failure on a high-priority message → still post the fallback (avoid
  deprioritization, E-F4).
- Seen/expired/superseded → no post; these are normal-priority in practice (retractions
  and progress) except a duplicate high-priority Command, which is the only case of a
  high message without a post — acceptable (one duplicate) and recorded for V-A6.

## Compatibility and rollout

Same `v`/frame gates as iOS.

## Verification

`aiur-client-core/src/test/kotlin/push/AcceptanceTest.kt` (PROPOSED): one test per
`vectors.json` case (verdicts), plus:

| Test | Expected | Must fail without |
| --- | --- | --- |
| `highPriorityDecryptFailureStillPosts` | `Fallback` result flagged `mustPost` | return `Drop` |
| `lockedKeysFallBack` | `Fallback(LOCKED)` | show cached content |
| `invalidatedMasterKeyPostsFallbackNotNothing` | `Fallback(KEYS_UNAVAILABLE)` with `mustPost` for a normal-priority payload too | map `KeysUnavailable` to unknown-kid `Drop` |
| `unknownKidOnReadableKeysetIsDropped` | `Drop(UNKNOWN_KID)`, nothing posted for normal priority | post fallback for every failure |
| `everyVerifiedHighIsShown` (property over accept vectors with `urgency: high`) | `Show` | filter by preference on device |

Commands: `./gradlew :aiur-client-core:test`. Device: V-A1, V-A5, V-A6 in C7.

## Completion and handoff

- [ ] Vector parity with iOS (same verdicts).
- Dependents: C5-T03, C5-T04, MP-N6-C2.
