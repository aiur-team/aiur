---
ticket_id: MP-N1-C2-T01
feature_id: MP-N1
chunk_id: MP-N1-C2
bucket: 3-mobile-watch
title: Apple native core (AiurClientKit) — shared-keychain store and per-machine Secure Enclave device auth key
status: blocked
blocked_by: [DESIGN-N1, MP-N1-C1-T03]
prior_units: []
prior_boundaries: []
prior_features: [MP-N2]
prior_findings: []
size_owner: n/a (new package)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C2-T01 — `AiurClientKit` (Swift): key and secret storage

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C2 (native cores and `AiurNative`).
- **User value:** device credentials live in hardware and the keychain, never in JavaScript
  or the WebView (reason R-secret, surface-boundary.md), so a compromised web page cannot
  steal the right to read or instruct agents.
- **Deliverable:** a Swift package `packages/aiur-mobile/native/apple-core/` (PROPOSED),
  product `AiurClientKit`, with:
  - `SecureStore`: generic-password items in the shared keychain access group
    (MP-N1-C1-T03), class `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
  - `DeviceAuthKey`: one P-256 signing key **per `machine_id`** in the Secure Enclave
    (non-exportable), created at pairing, deleted on unpair/revoke.
  - `MachineRecord` persistence: `{machine_id, machine_label, machine_key_pub (Ed25519, pinned),
    endpoints[], device_id, paired_at}` and the current access token with expiry, stored
    via `SecureStore` keyed by `machine_id`.
  - `wipe(machineId)` that removes every item for one machine; `wipeAll()`.
- **Non-goals:** pairing/token protocol logic (MP-N1-C2-T03), push keys and decryption
  (MP-N4-C4-T01/T02 put the X25519 push key in the same access group using this
  `SecureStore`), watch use (MP-N7-C2: the watch holds **no** keys, MP-N7 plan §8).

## Dependencies and blockers

- DESIGN-N1; MP-N1-C1-T03 (keychain access group exists).
- Contract inputs: `contracts/pairing-and-instance-registry.md` §2 (key separation: auth key
  P-256 hardware-bound; one auth key per machine, §5 "no cross-machine linkability").
- Concurrent with MP-N1-C2-T02 (Android core).

## Verified starting point (base 45a290e3)

- No Swift code exists in the repo (baseline N1).
- External (accessed 2026-10-06):
  - Secure Enclave "works only with NIST P-256 elliptic curve keys", keys cannot be moved in
    or out (<https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave>).
  - `kSecAttrAccessibleAfterFirstUnlock…` items are unreadable after restart until first
    unlock and are "recommended for items that need to be accessed by background
    applications" (<https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlock>,
    iOS 4.0+, S5).
  - The Secure Enclave is not available in the iOS Simulator (Apple: "Secure Enclave … on
    devices with" the hardware; same page). Tests therefore inject a software key.

## Chosen design

```swift
public protocol SigningKey { func publicKeySPKI() throws -> Data
                             func sign(_ message: Data) throws -> Data }   // DER ECDSA, SHA-256
public enum DeviceAuthKey {
  static func create(machineId: String, store: KeyBackend) throws -> SigningKey
  static func load(machineId: String, store: KeyBackend) throws -> SigningKey?
  static func delete(machineId: String, store: KeyBackend) throws
}
public protocol KeyBackend { … }     // SecureEnclaveBackend (device) | SoftwareBackend (tests only, #if DEBUG)
public struct SecureStore { init(accessGroup: String); func put(_:for:) ; func get(_:) ; func delete(prefix:) }
```

- SE key attributes: `kSecAttrTokenIDSecureEnclave`, `kSecAttrKeyTypeECSECPrimeRandom`, 256
  bits, `kSecAttrIsPermanent`, application tag `dev.aiur.mobile.auth.<machine_id>`, access
  control `SecAccessControlCreateWithFlags(…, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
  .privateKeyUsage, …)`. No biometric flag: token refresh must work when the broker is
  woken in the background by the watch (MP-N7 plan §3); biometric gating would be a product
  change and is not in DESIGN-N1.
- Signature format: `SecKeyCreateSignature(…, .ecdsaSignatureMessageX962SHA256, …)` (DER).
  MP-N2-C5-T03 verifies with Erlang `:public_key.verify/4`, which takes DER for ECDSA.
- SPKI export: `SecKeyCopyExternalRepresentation` gives the X9.63 point; the core prepends the
  fixed P-256 SPKI header so the gateway receives standard SPKI (contract §4.1
  `auth_public_key: <P-256 SPKI b64url>`).
- `SecureStore` keys: `machine/<machine_id>/record`, `machine/<machine_id>/token`.
  Values are JSON (`Codable`), never logged.
- Why per-machine keys: contract §5 multiple machines; one shared public key would let two
  machines correlate the same phone.

## Implementation steps

1. `Package.swift` (swift-tools 5.10+, platforms iOS 17, watchOS 10 — the watch links models
   only), targets `AiurClientKit` and `AiurClientKitTests`.
2. `SecureStore.swift` (SecItemAdd/CopyMatching/Update/Delete with `kSecAttrAccessGroup`).
3. `DeviceAuthKey.swift` with `SecureEnclaveBackend` and debug-only `SoftwareBackend`
   (`SecKeyCreateRandomKey` without the token id).
4. `MachineRecord.swift` (`Codable`) and `MachineVault.swift` (`save/load/list/wipe/wipeAll`).
5. Link the package into the app via the Expo module (MP-N1-C2-T05) and into the NSE target
   (MP-N1-C1-T03 folder) as a local Swift package dependency.

## Non-happy paths

- **Before first unlock:** reads throw `errSecInteractionNotAllowed`; the core maps it to
  `.lockedBeforeFirstUnlock` (a typed error, not "not paired"). Callers show the generic
  placeholder (DV-P3).
- **Key missing but record present** (restore to a new phone; SE keys never migrate because
  `ThisDeviceOnly`): `load` returns nil → the machine is presented as "needs re-pair",
  record wiped. Never re-create a key silently for an existing `device_id`.
- **Duplicate pairing of the same machine:** `create` refuses if a key exists for that
  `machine_id` unless called through the relink path (MP-N1-C2-T03), which reuses it.
- **Privacy:** no `print`/`os_log` of values; a unit test greps the module sources for logging
  of `token|secret|key` variables (see Verification).

## Compatibility and rollout

- New code; no daemon or config change. Rollback: unlink the package.
- Data migration n/a (first version). Schema of `MachineRecord` carries `v: 1`.

## Verification

- Command (macOS): `xcodebuild test -scheme AiurClientKit -destination 'platform=iOS
  Simulator,name=iPhone 16,OS=latest'` run in `packages/aiur-mobile/native/apple-core`
  (via `env -C`).
- XCTest cases (all use `SoftwareBackend` + a unique test access group or the default group in
  the simulator):
  - `testSignatureVerifiesWithExportedSPKI`: sign "abc", verify with `SecKeyVerifySignature`
    using the key rebuilt from the exported SPKI. Mutation: export raw X9.63 without the SPKI
    header → fails.
  - `testKeysArePerMachine`: create for m1 and m2 → different SPKI. Mutation: use a constant tag
    → fails.
  - `testWipeRemovesRecordTokenAndKey`: after `wipe("m1")`, `load` returns nil for record, token
    and key; m2 untouched. Mutation: skip key deletion → fails.
  - `testCreateRefusesExistingMachineKey`. Mutation: remove the guard → fails.
  - `testLockedErrorIsTyped`: inject a backend returning `errSecInteractionNotAllowed` →
    `.lockedBeforeFirstUnlock`. Mutation: map to `nil` (not paired) → fails.
- Source scan test `testNoSecretLogging`: reads the package sources (bundle resource copy) and
  fails on `print(`/`Logger` lines containing `token`, `secret` or `privateKey`.
- **Device:** iPhone A (iOS 17.x) and iPhone on iOS 26.x: debug screen (MP-N1-C5-T03) creates a
  key, shows `kSecAttrTokenIDSecureEnclave` present; reboot without unlock + test push →
  NSE cannot read the token item (DV-P3 precondition). Record device and OS build.

## Completion and handoff

- [ ] All XCTests pass on the simulator; mutations fail them.
- [ ] Device check recorded (or "not validated: no Apple account").
- **Docs:** none user-facing (internal library). Package README lists the key classes.
- **Dependents:** MP-N1-C2-T03, MP-N1-C2-T05, MP-N4-C4-T01 (push key reuses `SecureStore`),
  MP-N7-C1-T02 (broker reads tokens).
