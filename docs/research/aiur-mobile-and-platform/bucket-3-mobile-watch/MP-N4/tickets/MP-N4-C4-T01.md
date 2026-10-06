---
ticket_id: MP-N4-C4-T01
feature_id: MP-N4
chunk_id: MP-N4-C4
bucket: 3-mobile-watch
title: iOS per-machine push keys and pinned machine keys in the shared keychain group
status: ready
blocked_by: [DESIGN-N4, DESIGN-N1, N1-C2-T1, N1-C6-T1, MP-N2-C5-T5]
prior_units: []
prior_boundaries: [mobile-app (MP-R1 component-map), push-relay]
prior_features: [MP-N1, MP-N2]
prior_findings: [E-B3, E-B4, E-C1, KD-N4-8]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C4-T01 — iOS push key storage

## Identity and outcome

Bucket 3, MP-N4, chunk C4. In the Swift core `AiurClientKit` (MP-N1-C2, PROPOSED under
`packages/aiur-mobile/`), add `PushKeyStore`:

- `createKey(machineId:deviceId:) -> (kid, x25519PublicRaw)`: generates a
  `Curve25519.KeyAgreement.PrivateKey` on device, stores it as a keychain item in the
  access group shared by the app and its Notification Service Extension, accessibility
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; records `kid → {machine_id,
  device_id}`.
- `privateKey(kid:)`, `entry(kid:)`, `rotate(machineId:)` (keeps current + previous),
  `deleteAll(machineId:)` (unpair, `device_revoked`).
- `pinMachineKey(machineId:ed25519PublicRaw:)` / `machineKey(machineId:)` — the Ed25519
  key pinned from the pairing QR (pairing contract §3 `k=`), same access group and class.

Non-goals: decrypt/verify (C4-T02), the NSE target and entitlements (N1-C6-T1), the
generic keychain wrapper (N1-C2-T1).

## Dependencies and blockers

- DESIGN-N4 gate (C4 is user-facing as a whole); this ticket's content does not depend on
  design answers. DESIGN-N1 (app exists).
- N1-C2-T1 (keychain wrapper with the shared access group), N1-C6-T1 (NSE target, app
  group and keychain group entitlements), MP-N2-C5-T5 (pairing client hands over
  `machine_id`, `device_id`, machine public key).
- Boundary with MP-N1: N1 owns the wrapper and targets; this ticket owns which items
  exist, their accessibility class and the `kid` mapping (contract v2 §4, PC-3).

## Verified starting point

- No mobile code at `45a290e3` (`packages/` has `aiur-style`, `streamdeck` only).
- Apple (accessed 2026-10-06): `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` —
  unavailable after restart until first unlock, "recommended for items that need to be
  accessed by background applications", not migrated (E-B3); keychain access groups
  share items among a team's apps and extensions (E-B4); CryptoKit HPKE
  `Ciphersuite.Curve25519_SHA256_ChachaPoly`, iOS 17.0+ (E-C1, page metadata).
- Contract v2 §4: one X25519 key per device install **per machine**; `kid` = `k_` + 26
  base32 chars; device keeps `kid → {machine_id, device_id, key}`; two keys during
  rotation.

## Chosen design

- Keychain item: class `kSecClassGenericPassword`, service `aiur.push.v1`, account `kid`,
  value = raw 32-byte private key, `kSecAttrAccessGroup` = the shared group,
  `kSecAttrSynchronizable = false`.
- Mapping file: `kid → {machine_id, device_id, created_at}` stored in the same keychain
  (second item, service `aiur.push.v1.map`) so the NSE needs no file with weaker
  protection.
- Machine keys: service `aiur.machine.v1`, account `machine_id`.
- Minimum OS iOS 17 / watchOS 10 (KD-N4-8).

## Implementation steps

1. `AiurClientKit/Sources/Push/PushKeyStore.swift` (PROPOSED).
2. Called from the pairing flow (MP-N2 client) after claim; result feeds C4-T05.
3. Unit tests with an in-memory keychain fake + one device test in C7.

## Non-happy paths

- Keychain unavailable before first unlock (background launch): `privateKey(kid:)` throws
  `.locked`; C4-T02 maps it to the fallback.
- Item missing for a known `kid` (restored backup — items are ThisDeviceOnly): treat as
  unknown `kid`; app prompts re-pair for that machine (DESIGN-N2 state).
- `device_revoked` (pairing contract §4.2) → `deleteAll(machineId:)`.

## Compatibility and rollout

New keychain items only. Rotation keeps the previous `kid` until the daemon confirms the
new registration (C4-T05).

## Verification

XCTest `AiurClientKitTests/PushKeyStoreTests.swift` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `testItemsUseAfterFirstUnlockThisDeviceOnly` | query attributes equal the constant | default accessibility |
| `testItemsAreInSharedAccessGroup` | attribute set | omit the group |
| `testOneKeyPerMachine` | two machines → two kids, two keys | reuse a key |
| `testRotateKeepsPrevious` | both kids resolvable | delete previous on rotate |
| `testRevokeDeletesMachineItemsOnly` | other machine intact | delete all |

Command: `xcodebuild test -scheme AiurClientKit -destination 'platform=iOS Simulator,name=iPhone 16'`
(path per MP-N1-C1 build docs). Device check in C7 (V-I3 relies on this class).

## Completion and handoff

- [ ] Accessibility class asserted in tests.
- Dependents: C4-T02, C4-T05, MP-N7 (watch keys reuse the pattern).
