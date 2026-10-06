---
ticket_id: MP-N4-C4-T02
feature_id: MP-N4
chunk_id: MP-N4-C4
bucket: 3-mobile-watch
title: iOS payload acceptance pipeline — open, verify, expiry, seen-nid, stream supersession
status: ready
blocked_by: [DESIGN-N4, MP-N4-C4-T01, MP-N4-C1-T04, MP-N1-C2-T03, MP-N1-C6-T01]
prior_units: []
prior_boundaries: [mobile-app, push-relay]
prior_features: [MP-N1]
prior_findings: [E-A3 (NSE ~30 s, original content on failure), E-C1]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C4-T02 — iOS acceptance pipeline

## Identity and outcome

Bucket 3, MP-N4, chunk C4. A pure Swift function in `AiurClientKit`:

```swift
func accept(userInfo: [AnyHashable: Any], now: Date, keys: PushKeyStore,
            seen: SeenStore) -> AcceptResult
enum AcceptResult { case show(ProtectedPayload), drop(Reason), fallback(Reason) }
```

Steps (contract v2 §4–§6): read `s`, `k`, `v` → `v == 1` → `kid` known → derive `info`
→ CryptoKit `HPKE.Recipient(privateKey:ciphersuite:info:encapsulatedKey:)` with
`.Curve25519_SHA256_ChachaPoly`, `open(ct, authenticating: Data())` → frame byte `0x01`
→ Ed25519 verify over `"aiur-push-v1-sig" ‖ 0x00 ‖ info ‖ payload` with the pinned
machine key → parse JSON → `destination.machine_id` equals kid's machine,
`instance_id` prefixed → `expires_at` ≥ now − 5 min → `nid` unseen → stream/seq not
superseded → `.show`. The NSE (N1-C6-T01) calls it and applies the result; on `.fallback`
it calls the completion handler with the original (uniform) content.

Non-goals: titles/categories (C4-T03), retraction (C4-T04), raw HPKE open (N1-C2-T03 — this
ticket uses it).

## Dependencies and blockers

- C4-T01 (keys), C1-T04 (vectors), N1-C2-T03 (native HPKE open helper), N1-C6-T01 (NSE).
- DESIGN-N4 gate; the logic is fixed by the contract, so no design answer changes it.
- RQ-N4-5 / OQ-N4-3 do not affect this ticket: whether a rejected payload can be
  suppressed silently (filtering entitlement, E-A7) is C4-T03/T04 presentation.

## Verified starting point

- Apple (accessed 2026-10-06): NSE runs only with `mutable-content: 1` and an alert;
  "only about 30 seconds"; on failure "the system displays the original contents"
  (E-A3). CryptoKit `HPKE.Recipient.init(privateKey:ciphersuite:info:encapsulatedKey:)`
  and `open(_:authenticating:)` (developer.apple.com/documentation/cryptokit/hpke/recipient).
- Vectors: `vectors.json` (C1-T04) with accept/reject verdicts.

## Chosen design

- Self-imposed budget 5 s (plan C4-T02) — the function is CPU-only, no network
  (KD-N4-6).
- `SeenStore`: file in the app-group container with
  `FileProtectionType.completeUntilFirstUserAuthentication`; ring of the last 512 `nid`s
  plus per-stream highest `seq`; entries older than 30 days pruned.
- Every failure returns `.fallback(reason)` or `.drop(reason)`, never throws to the NSE:
  `.drop` for `nid` seen / superseded / expired (nothing new to show); `.fallback` for
  crypto, frame, unknown kid, locked keychain, unknown `v`.
- **Local key loss is its own reason (Phase D M6).** A keychain read error other than
  `errSecInteractionNotAllowed` (which is `.locked`) — e.g. `errSecItemNotFound` for a
  `kid` the mapping still lists, or a decode failure of the stored key — returns
  `.fallback(.keysUnavailable)`, never `.fallback(.unknownKid)`. The NSE shows the
  uniform fallback and writes `pushHealth = keysLost` for that machine to the app group;
  the app reports `push_health: keys_lost` (contract §7) on its next online call.
- **Last notified destination (Phase D, handoff from MP-N7 for feasibility M5).** On every
  `.show` of a `command.*` payload, `Acceptance` returns the decrypted `destination` (contract
  §3.1) with the verdict, and the NSE glue writes `{destination, nid, at}` to the app-group
  key `aiur.lastNotifiedDestination` (file protection
  `completeUntilFirstUserAuthentication`). Only the destination is stored: it names objects
  and carries no summary text. The phone app reads it to answer the watch's
  `get_command {latest_notified: true}` (MP-N7-C2-T04) within 15 minutes; it is overwritten
  by the next Command and cleared on unpair.

## Implementation steps

1. `AiurClientKit/Sources/Push/Acceptance.swift`, `SeenStore.swift` (PROPOSED).
2. Vector-driven XCTest.
3. NSE glue lives in N1-C6-T01; this ticket provides the call.

## Non-happy paths

- Device restarted, not unlocked: keychain `.locked` → `.fallback(.locked)` (V-I3).
- Clock skew: 5-minute tolerance on `expires_at`.
- Corrupt `SeenStore`: reset it and continue (a duplicate display is better than a
  missed blocker).

## Compatibility and rollout

`v`/frame version gate; unknown → fallback + "update the app" flag for the app UI.

## Verification

XCTest `AiurClientKitTests/AcceptanceTests.swift` (PROPOSED): one test per
`vectors.json` case asserting the case `verdict` (accept → `.show`; each reject →
the right `.fallback`/`.drop`), plus:

| Test | Expected | Must fail without (unknown-path rule) |
| --- | --- | --- |
| `testLockedKeychainFallsBack` | `.fallback(.locked)` | replace the locked branch with `.show` of cached content |
| `testExpiredIsDropped` | `.drop(.expired)` | skip the expiry check |
| `testSeenNidIsDropped` | second call `.drop(.seen)` | no SeenStore write |
| `testWrongMachineDestinationFallsBack` | `.fallback(.destinationMismatch)` | skip the machine check |
| `testShowWritesLastNotifiedDestination` | after `.show` of a `command.needs_you` vector the app-group store holds that `destination` and `nid`, and no `summary` field; a `.fallback` or `.drop` verdict writes nothing | the write (watch fallback-open then finds nothing) |
| `testKeychainReadErrorIsKeysUnavailable` (stub keychain returns `errSecItemNotFound` for a mapped `kid`) | `.fallback(.keysUnavailable)` and `pushHealth == .keysLost` | collapse into `.unknownKid` |

Commands: `xcodebuild test -scheme AiurClientKit …` (per MP-N1-C1). Device: V-I1, V-I3,
V-S1 in C7.

## Completion and handoff

- [ ] Every vector case passes; mutation results in PR.
- Dependents: C4-T03, C4-T04, MP-N6-C2 (destination from `.show` payload).
