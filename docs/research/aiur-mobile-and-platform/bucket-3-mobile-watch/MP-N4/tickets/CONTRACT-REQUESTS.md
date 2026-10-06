# MP-N4 contract requests (for the coordinator)

MP-N4 owns `contracts/notification-destination-and-payload.md` and has updated it to v2
(§11 lists the changes). The items below are changes to contracts or plans MP-N4 does
**not** own. Researched 2026-10-06 at base `45a290e3`.

| ID | Target (owner) | Request | Why | Blocks |
| --- | --- | --- | --- | --- |
| CR-N4-1 | `pairing-and-instance-registry.md` §2 (MP-N2) | Replace "Device push key (P-256 ECDH or the scheme MP-N4 picks)" with: X25519, one key pair **per device install per paired machine**, storage class `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (iOS) / Keystore-wrapped Tink keyset without unlocked-device requirement (Android); `kid` maps to `{machine_id, device_id}`. | Contract v2 §4 (PC-3); the per-machine key lets the device rebuild the HPKE `info` before decrypting. | none (text alignment) |
| CR-N4-2 | MP-N2-C1 store library (MP-N2) | Expose a read-only signing function for instance daemons, e.g. `Aiur.Machine.Store.sign(message) :: {:ok, <<_::512>>} \| {:error, reason}`, so push-relay never copies the `machine_key` private bytes. If declined, confirm instances may read `machine_key` through the store library. | Contract v2 §4 signature; pairing contract §5 says instances read only. | MP-N4-C3-T03 chooses the signer source; ticket implementable either way |
| CR-N4-3 | `pairing-and-instance-registry.md` §4 (MP-N2) | Add a token-authenticated update call for a device's own `push_registration` after pairing (APNs/FCM token refresh, key rotation, permission state), e.g. `PUT /v1/devices/self/push`; the gateway stays the single writer. Accept an additive `capabilities.notifications_permitted` boolean in the opaque record. | Today only `POST /v1/pair/claim` carries `push`; tokens rotate (FCM `onNewToken`, APNs re-registration) and permission can be denied after pairing (plan §7.2). | MP-N4-C4-T05, MP-N4-C5-T05 (merge) |
| CR-N4-4 | `identity-and-capabilities.md` §2.2 (MP-R1) | Register `depends_on` ids `runtime.crypto` and `pairing` for `push` (`dependency_unavailable`), and note that `push` is reported in every run shape with the event bus (including `--no-dashboard`). | MP-N4-C3-T04 capability table; AC-N4-8 "never silently missing". | MP-N4-C3-T04 (naming only) |
| CR-N4-5 | `pairing-and-instance-registry.md` §8 (MP-N2) | Add the `push:` section to the `~/.aiur/machine` example: `enabled: false`, `send_timeout_ms: 5000`, `outbox.max_age_seconds: 86400`, `allow_loopback_relay: false`; MP-N2-C3-T1's loader accepts a section registered by the push component; MP-N2-C3-T5's docs check covers it. | RC-03 moves push settings out of `~/.aiur/config`. | MP-N4-C3-T01 |
| CR-N4-6 | MP-N1 chunks N1-C2-T3, N1-C6 (MP-N1) | (a) N1-C2-T3's native open must use HPKE `info` = `aiur-push-v1` ‖ 0 ‖ `device_id` ‖ 0 ‖ `kid`, empty AAD, Tink RAW output prefix, and the `vectors.json` from MP-N4-C1-T04. (b) Record the split: N1 owns targets, entitlements, wrappers, raw open, registration hand-off; MP-N4-C4/C5 own key inventory, acceptance pipeline, presentation, retraction, relay registration. (c) Minimum iOS 17 / watchOS 10 (KD-N4-8, CryptoKit HPKE). | Avoid duplicate NSE/FCM work and interop drift. | MP-N4-C4-T01/T02, MP-N4-C5-T01/T02 |

## Notes for other features (no change requested)

- MP-N5 writes intents into the MP-N4 outbox (`Aiur.Push.Outbox.accept/2`, C3-T02) and
  provides the send-time staleness hook (`Aiur.Push.Outbox.StalenessHook`, implemented in
  MP-N5-C3-T03).
- MP-N6-C2 reads the accepted payload's `destination` (contract v2 §3.1, now with
  `instance_id`).
- RC-01 vs pairing contract §1: the pairing contract still says `machine_id` is made by
  `aiur mobile enable`; RC-01 says first daemon boot. MP-N4 only reads it; flagged for the
  MP-N2 owner.
