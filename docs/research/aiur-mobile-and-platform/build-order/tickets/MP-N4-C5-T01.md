---
ticket_id: MP-N4-C5-T01
feature_id: MP-N4
chunk_id: MP-N4-C5
bucket: 3-mobile-watch
title: Android per-machine Tink HPKE keysets and pinned machine keys
status: ready
blocked_by: [DESIGN-N4, DESIGN-N1, MP-N1-C2-T02, MP-N2-C5-T05]
prior_units: []
prior_boundaries: [mobile-app, push-relay]
prior_features: [MP-N1, MP-N2]
prior_findings: [E-C2, E-C5, E-F9]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C5-T01 — Android push key storage

## Identity and outcome

Bucket 3, MP-N4, chunk C5. In the Kotlin core `aiur-client-core` (MP-N1-C2, PROPOSED),
add `PushKeyStore`: one Tink HPKE keyset per paired machine with template
`DHKEM_X25519_HKDF_SHA256_HKDF_SHA256_CHACHA20_POLY1305` and **RAW** output prefix (so the
wire format is `enc ‖ ct ‖ tag`, contract v2 §4), wrapped by an Android Keystore AES key
created **without** `setUnlockedDeviceRequired(true)`, stored in credential-encrypted
storage; `kid → {machine_id, device_id}` mapping; raw 32-byte X25519 public key export
for registration; pinned Ed25519 machine keys.

## Dependencies and blockers

- N1-C2-T02 (Keystore wrapper), MP-N2-C5-T05 (pairing hand-off), DESIGN-N4 gate (no design
  content needed here), DESIGN-N1.

## Verified starting point

- E-C2: Tink hybrid implements RFC 9180 with template
  `DHKEM_X25519_HKDF_SHA256_HKDF_SHA256_CHACHA20_POLY1305` (developers.google.com/tink/hybrid,
  updated 2025-03-03).
- E-C5: Tink `HybridDecrypt` passes `contextInfo` as HPKE `info`, empty AAD; RAW wire
  format `enc ‖ ct ‖ tag` (tink-java `HpkeDecrypt.java` @ `d042a5f7`; wire-format page
  updated 2026-09-30).
- E-F9: credential-encrypted storage is available only after first unlock;
  `setUnlockedDeviceRequired` restricts a key to unlocked use (developer.android.com,
  updated 2026-10-01).
- **To confirm in this ticket:** the Tink API that exports the raw X25519 public key bytes
  from an HPKE public keyset (Tink Java `HpkePublicKey` key object). If no public accessor
  exists in the pinned Tink version, serialize the public keyset and extract the
  `public_key` field — record the method and Tink version in platform-evidence.md.

## Chosen design

- Tink version pinned in the Gradle catalog (MP-N1-C1-T04 pins versions).
- Keyset handle stored with `AndroidKeysetManager` (keyset encrypted by the Keystore
  master key, `withMasterKeyUri("android-keystore://aiur_push_master")`), master key
  generated without unlocked-device requirement.
- One keyset per machine, rotation = add key + set primary, keep previous for one cycle.
- Machine Ed25519 public keys: Tink `Ed25519` verify (`PublicKeyVerify`) or BouncyCastle
  if Tink import of raw keys is not public — decided with the export question above.

## Implementation steps

1. `aiur-client-core/src/main/kotlin/push/PushKeyStore.kt` (PROPOSED).
2. Pairing hook; revoke wipe.
3. Tests (Robolectric or instrumented for Keystore).

## Non-happy paths

- Before first unlock: credential-encrypted storage unavailable → `Locked`. The messaging
  service is **not** direct-boot-aware (RQ-N4-4 settled, E-F9), so in practice FCM
  messages are handled after first unlock; `Locked` remains a defensive state.
- Keystore key invalidated (e.g. lock-screen removal on some OEMs) or keyset unreadable
  → `KeysUnavailable(machine_id?)`, a **local** cause, never mapped to unknown kid
  (Phase D M6; AGENTS.md collapsed-cause rule). C5-T02 posts the uniform fallback; the
  store sets `pushHealth = KEYS_LOST` for that machine, which the app reports as
  `push_health: keys_lost` (contract §7) on its next online call through the MP-N2
  gateway re-registration; the in-app open shows "Open aiur to re-pair".

## Compatibility and rollout

Min SDK per MP-N1; Tink has no extra OS floor (KD-N4-8).

## Verification

`aiur-client-core/src/test/kotlin/push/PushKeyStoreTest.kt` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `rawOutputPrefixMatchesContract` | decrypt of a C1-T04 vector `sealed` succeeds | TINK output prefix (5-byte header) |
| `masterKeyNotUnlockedDeviceRequired` (instrumented) | key spec flag false | set the flag |
| `onePerMachine` | 2 machines → 2 keysets | shared keyset |
| `exportsRaw32BytePublicKey` | 32 bytes, equals vector pubkey for imported fixture | export serialized keyset |
| `invalidatedMasterKeyIsKeysUnavailableNotUnknownKid` (instrumented: delete `aiur_push_master` from the Keystore) | `KeysUnavailable`, `pushHealth == KEYS_LOST` | map the read failure to unknown kid |

Commands: `./gradlew :aiur-client-core:test` (and `connectedAndroidTest` for Keystore),
paths per MP-N1-C1. Device: V-A1, V-A3 in C7.

## Completion and handoff

- [ ] Export method + Tink version recorded in platform-evidence.md.
- [ ] E-F7 re-read (Phase D m10): read the FCM troubleshooting page and the Android
  "stopped state" documentation, record a dated quote for force-stopped delivery in
  platform-evidence.md E-F7; V-A4 stays the deciding row.
- Dependents: C5-T02, C5-T05.
