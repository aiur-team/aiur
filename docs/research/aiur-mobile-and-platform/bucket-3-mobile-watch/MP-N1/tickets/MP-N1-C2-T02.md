---
ticket_id: MP-N1-C2-T02
feature_id: MP-N1
chunk_id: MP-N1-C2
bucket: 3-mobile-watch
title: Android native core (aiur-client-core) — Keystore device auth key per machine and Keystore-wrapped secret file
status: blocked
blocked_by: [DESIGN-N1, MP-N1-C1-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-N2]
prior_findings: []
size_owner: n/a (new package)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C2-T02 — `aiur-client-core` (Kotlin): key and secret storage

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C2.
- **User value:** same as MP-N1-C2-T01 on Android: credentials in the Keystore, never in JS.
- **Deliverable:** Gradle library module `packages/aiur-mobile/native/android-core/`
  (PROPOSED), package `dev.aiur.client.core`, with:
  - `DeviceAuthKey`: P-256 signing key per `machine_id` in Android Keystore, StrongBox when
    available, else TEE; alias `aiur.auth.<machine_id>`; `SHA256withECDSA` (DER signatures).
  - `SecretFile`: a JSON file in app-private storage (`noBackupFilesDir/aiur/vault.json`)
    encrypted with a Keystore AES-256-GCM key (alias `aiur.vault`), holding the same
    `MachineRecord` and token fields as the Apple core.
  - `wipe(machineId)`, `wipeAll()`.
- **Non-goals:** protocol (MP-N1-C2-T03); push keys (MP-N4-C5-T01 uses Tink with its own
  Keystore-wrapped keyset); Wear OS (the watch holds no keys, MP-N7 plan §8).

## Dependencies and blockers

- DESIGN-N1; MP-N1-C1-T01. Concurrent with MP-N1-C2-T01.
- Contract: `pairing-and-instance-registry.md` §2.

## Verified starting point (base 45a290e3)

- No Kotlin/Java code in the repo (baseline N1).
- External (accessed 2026-10-06):
  - Keystore keys bound to secure hardware are "never exposed outside of secure hardware";
    StrongBox supports "ECDSA, ECDH P-256"
    (<https://developer.android.com/privacy-and-security/keystore>).
  - `androidx.security:security-crypto` (EncryptedSharedPreferences, EncryptedFile,
    MasterKey) is **deprecated** since 1.1.0-beta01 (2025-06-04), "in favour of existing
    platform APIs and direct use of Android Keystore"
    (<https://developer.android.com/jetpack/androidx/releases/security>). Hence the
    hand-rolled `SecretFile` instead of the plan's "encrypted preferences".
  - Robolectric does not emulate `AndroidKeyStore`; Keystore tests run as instrumented tests
    on an emulator or device (standard Android test split; no source claim needed beyond the
    `KeyStore.getInstance("AndroidKeyStore")` provider being device-only).

## Chosen design

```kotlin
interface SigningKey { fun publicKeySpki(): ByteArray; fun sign(message: ByteArray): ByteArray }
object DeviceAuthKey {
  fun create(machineId: String, backend: KeyBackend): SigningKey   // refuses if alias exists
  fun load(machineId: String, backend: KeyBackend): SigningKey?
  fun delete(machineId: String, backend: KeyBackend)
}
class SecretFile(dir: File, aead: Aead)          // Aead = Keystore AES-GCM in prod, in-memory in unit tests
class MachineVault(file: SecretFile) { save; load; list; wipe(machineId); wipeAll() }
```

- `KeyGenParameterSpec.Builder(alias, PURPOSE_SIGN)` with `setAlgorithmParameterSpec(
  ECGenParameterSpec("secp256r1"))`, `setDigests(DIGEST_SHA256)`,
  `setIsStrongBoxBacked(true)` with a catch of `StrongBoxUnavailableException` → retry without.
  `setUserAuthenticationRequired(false)` and **no** `setUnlockedDeviceRequired(true)`: the
  watch broker and FCM service may refresh tokens while the phone is locked (MP-N7-C1-T03,
  MP-N4-C5). Same reason as the Apple core's AfterFirstUnlock class.
- `getEncoded()` on the EC public key returns X.509 SPKI already (contract format).
- `SecretFile`: AES/GCM/NoPadding, 12-byte random IV per write, AAD = `"aiur.vault.v1"`,
  atomic write (temp file + `renameTo`). File in `noBackupFilesDir` so Auto Backup never copies
  it (the Keystore key would not restore anyway).

## Implementation steps

1. Module `native/android-core` with `build.gradle.kts` (Android library, minSdk 29,
   Kotlin JVM target 17, `kotlinx-serialization-json`).
2. `KeyBackend` (`AndroidKeystoreBackend`, test `SoftwareBackend` using `KeyPairGenerator("EC")`).
3. `DeviceAuthKey.kt`, `SecretFile.kt`, `MachineVault.kt`, `MachineRecord.kt` (`@Serializable`,
   `v = 1`).
4. Include the module from the generated Android project through the Expo module's
   `android/build.gradle` (MP-N1-C2-T05) so it survives prebuild.

## Non-happy paths

- **Key invalidated** (`KeyPermanentlyInvalidatedException`, or alias missing after a factory
  reset restore): treat as "needs re-pair", wipe that machine's record. Never silently recreate.
- **Vault decrypt failure** (`AEADBadTagException`, corrupt file): rename the file to
  `vault.json.corrupt-<ts>`, return `VaultCorrupt` so the UI shows every machine as needing
  re-pair. No partial reads.
- **StrongBox missing:** TEE fallback, recorded in the key info (`KeyInfo.securityLevel`, API
  31+) for the diagnostics screen.
- **Privacy:** no `Log.*` of values; source-scan test as on Apple.

## Compatibility and rollout

- New code. Rollback: remove the module include. Vault schema `v: 1`.

## Verification

- JVM unit tests: `./gradlew :aiur-client-core:testDebugUnitTest` (run in the generated
  `android/` via `env -C packages/aiur-mobile/android`):
  - `vault round trip preserves records` and `wipe removes only one machine`. Mutation: make
    `wipe` clear the file → second test fails.
  - `tampered ciphertext yields VaultCorrupt` (flip one byte). Mutation: catch and return empty
    vault → fails.
  - `sign verifies with exported SPKI` (software backend). Mutation: return `encoded` of the
    private key → fails.
- Instrumented: `./gradlew :aiur-client-core:connectedDebugAndroidTest` on an API 34 emulator:
  - `keystore key is non-exportable` (`KeyInfo.isInsideSecureHardware` or `securityLevel !=
    SOFTWARE` on hardware-backed images; on the emulator assert `privateKey.encoded == null`).
  - `create refuses existing alias`. Mutation: remove guard → fails.
- Source scan: `no secret logging` (JVM test reading `src/main` for `Log.` lines with
  `token|secret|privateKey`).
- **Device:** Android phone A (Android 13+, Pixel-class with Play services): debug screen shows
  security level `STRONGBOX` or `TRUSTED_ENVIRONMENT`; lock the phone and trigger a token
  refresh from an `adb shell am broadcast` debug receiver → refresh succeeds (precondition for
  DV-W2 Wear equivalent and DV-P4).

## Completion and handoff

- [ ] Unit and instrumented tests pass; mutations fail.
- [ ] Device security level recorded.
- **Docs:** none user-facing.
- **Dependents:** MP-N1-C2-T03, MP-N1-C2-T05, MP-N7-C1-T03, MP-N4-C5-T01 (shares the vault
  pattern, not the key).
