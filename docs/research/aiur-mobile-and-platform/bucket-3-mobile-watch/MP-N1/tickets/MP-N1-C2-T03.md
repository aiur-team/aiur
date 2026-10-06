---
ticket_id: MP-N1-C2-T03
feature_id: MP-N1
chunk_id: MP-N1-C2
bucket: 3-mobile-watch
title: Device-side pairing and token protocol in both native cores (QR verify, claim/relink, challenge signing, token refresh, endpoint failover) against MP-N2 vectors
status: blocked
blocked_by: [DESIGN-N1, MP-N1-C2-T01, MP-N1-C2-T02, MP-N2-C5-T05, MP-N2-C5-T03, MP-N2-C5-T04]
prior_units: []
prior_boundaries: []
prior_features: [MP-N2]
prior_findings: []
size_owner: n/a (new package)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N1-C2-T03 — Pairing and token client in `AiurClientKit` and `aiur-client-core`

Candidate N1-C2-T4 ("request signing against shared vectors"), widened to the whole
device side of contract §3–§4 because signing alone is not a usable outcome.

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N1 / MP-N1-C2.
- **User value:** a phone pairs once per machine and keeps working across restarts, address
  changes and token expiry without the operator re-scanning.
- **Deliverable:** in both cores (Swift and Kotlin, identical behaviour):
  - `PairingQr.parse(uri) -> PairingOffer` and Ed25519 verification of `sig` with `k`
    (contract §3), including the optional `t=` pin parameter (RQ-TRANSPORT option T-B).
  - `claim(offer)` / `relink(offer)` (§4.1, §4.3): builds the body, the HMAC-SHA256
    `secret_proof`, sends it, verifies the response `sig` with the pinned key, persists the
    `MachineRecord` (MP-N1-C2-T01/T02).
  - `TokenManager.accessToken(machineId)`: single-flight challenge/sign/token (§4.2); refresh
    when < 3 min remain; on `401 device_revoked` → `wipe(machineId)` and emit a
    `MachineRevoked` event.
  - `EndpointSelector`: try stored endpoints in order with a 5 s connect timeout; on any
    successful `GET /v1/machine`, replace endpoints and label from the signed response (§4.3).
  - `TransportPolicy` hook: HTTPS uses the platform trust store (option T-A); when the
    machine record carries a pin (T-B) the core's URLSession/OkHttp delegate checks the SPKI
    hash; HTTP is allowed only when the record was paired from an `http://` endpoint and the
    build has the HTTP-degraded flag (MP-N1-C5-T02).
- **Non-goals:** UI (MP-N2 app first-run screens, blocked on DESIGN-N2), WebView cookies
  (MP-N1-C4-T02), the push registration blob (`push` field is passed through from MP-N4-C4-T05).

## Dependencies and blockers

- DESIGN-N1; MP-N1-C2-T01/T02 (storage).
- **MP-N2-C5-T05** (device-side reference client and test vectors), **MP-N2-C5-T03**
  (challenge/token endpoints), **MP-N2-C5-T04** (relink). The vectors are the cross-language
  contract; this ticket cannot finish before they exist.
- **RQ-TRANSPORT** only for the T-B pin branch: if DESIGN-N2 §transport picks T-A, the pin
  branch is not implemented (the parser still rejects nothing; it stores `t` if present).
- Concurrent with MP-N1-C2-T04.

## Verified starting point (base 45a290e3)

- Protocol source: `contracts/pairing-and-instance-registry.md` §3 (QR URI fields `m n e k s
  x t sig`), §4.1 claim, §4.2 challenge/token (TTL 15 min, nonce 60 s), §4.3 relink and
  `GET /v1/machine`, §4.5 `device_revoked`, §8.1 transport options.
- Daemon side is not implemented (MP-N2 chunks); there is no existing client to reuse.
- Existing server-side constant-time digest compare pattern the gateway will mirror:
  `src/lib/aiur_web/supervisor_auth.ex:78-82` (informational).
- External (accessed 2026-10-06):
  - Apple CryptoKit: `Curve25519.Signing.PublicKey(rawRepresentation:)` and
    `isValidSignature(_:for:)`; `HMAC<SHA256>` (<https://developer.apple.com/documentation/cryptokit>, iOS 13+).
  - Tink Java `com.google.crypto.tink.subtle.Ed25519Verify` (<https://developers.google.com/tink>);
    MP-N4-C5-T01 already adds Tink to the Android app, so no new dependency family.
    `javax.crypto.Mac.getInstance("HmacSHA256")` is platform API.

## Chosen design

- **Canonical bytes.** The HMAC input (claim body without `secret_proof`) and response
  signatures (body without `sig`) use RFC 8785 JSON canonicalization, the same scheme MP-N4
  uses for its ProtectedPayload (MP-N4-C1-T03). The challenge signature input is the UTF-8
  bytes of `nonce + "." + device_id + "." + machine_id`. **Both are contract requests to MP-N2**
  (§4.1 and §4.2 say "canonical(...)" and "nonce‖device_id‖machine_id" without fixing bytes);
  the MP-N2-C5-T05 vectors are authoritative if MP-N2 decides otherwise, and this ticket
  follows the vectors.
- **State machine per machine:**
  `unpaired → claiming → paired(token: none|valid(exp)|refreshing) → revoked(terminal)`;
  `paired → relinking → paired` on a QR whose `m` is known.
- **Pin mismatch** (`k` in a new QR differs from the stored key for the same `machine_id`):
  hard error `machine_key_mismatch` (contract §3 "never a silent re-pin").
- **Error typing** (no collapsed causes; AGENTS.md "collapsed cause"): `pair_secret_expired |
  pair_secret_used | pair_secret_unknown | pairing_disabled | device_limit | device_revoked |
  machine_key_mismatch | signature_invalid | transport(kind) | unknown(status)`, with `kind`
  from the client capability model I2 list.
- **Concurrency:** one in-flight token request per machine (actor on Swift; `Mutex` +
  `Deferred` on Kotlin). Callers await the same result.

## Implementation steps

1. Shared vector files copied (not hand-written) from MP-N2-C5-T05 into
   `packages/aiur-mobile/fixtures/contract/pairing/` with a `SOURCE` file naming the commit.
2. Swift: `PairingQr.swift`, `Canonical.swift` (RFC 8785 subset for objects/strings/integers
   used here), `PairingClient.swift`, `TokenManager.swift` (actor), `EndpointSelector.swift`,
   `TransportPolicy.swift` (URLSession delegate; pin check only when the record has `t`).
3. Kotlin: same files under `dev.aiur.client.core.pairing`; OkHttp (pinned version) with a
   `CertificatePinner`-equivalent custom `X509TrustManager` only for the T-B branch.
4. Both cores expose an async API used by MP-N1-C2-T05.

## Non-happy paths

- **Clock skew:** expiry decisions use the server's `expires_at` minus a 60 s margin measured
  from the local receipt time, not wall-clock comparison of the two clocks (contract §9 clock
  skew).
- **All endpoints fail:** state `unreachable(since)`; no wipe; UI offers re-scan (relink).
- **Revoked while offline:** first successful contact returns `device_revoked` → wipe.
- **Lost race:** two callers refreshing → single flight; the second gets the first's token.
- **Replay:** nonces are single-use server side; the client never caches a signed nonce.
- **Locked before first unlock:** storage error propagates as `locked` (MP-N1-C2-T01) and no
  network call is made.
- **Privacy:** tokens and secrets never logged; errors carry `device_id` at most.

## Compatibility and rollout

- Client-only. Contract version `aiur.machine/v1`; unknown major in a response → typed
  `contract_unsupported` → UI "Update the app" (`needs_update`).
- Rollback: n/a (no prior client).

## Verification

- Commands: `xcodebuild test -scheme AiurClientKit -destination 'platform=iOS
  Simulator,name=iPhone 16,OS=latest'` and `./gradlew :aiur-client-core:testDebugUnitTest`.
- Vector-driven tests (identical names in Swift and Kotlin):
  - `qr_vectors_verify` / `qr_tampered_label_fails`: every valid QR vector verifies; flipping
    one char of `n` fails. Mutation: skip signature check → tampered test fails.
  - `claim_proof_matches_vector`: computed `secret_proof` equals the vector byte-for-byte.
    Mutation: drop canonicalization (use insertion-order JSON) → fails.
  - `challenge_signature_verifies_against_vector_key`: with the vector's software key, the
    produced DER signature verifies with the vector public key.
  - `known_machine_qr_relinks_without_new_key`: second scan calls relink and keeps the key.
    Mutation: call claim → fails (mock server sees `/v1/pair/claim`).
  - `different_k_for_known_machine_is_hard_error`. Mutation: re-pin silently → fails.
  - `device_revoked_wipes_machine`. Mutation: retry instead of wipe → fails.
  - `concurrent_refresh_is_single_flight`: 10 concurrent callers → mock server counts one
    `/v1/token`. Mutation: remove the actor/mutex → count > 1.
  - `endpoints_replaced_from_signed_machine_response` and `unsigned_machine_response_rejected`.
- Integration (optional, macOS/Linux): run against the MP-N2-C5-T05 reference gateway harness
  if it offers a local server mode (`mise exec -- mix test` lives on the daemon side; not run here).
- **Device:** covered by MP-N2-C9-T02 (pairing on iPhone A and Android phone A over tailnet and
  LAN, after gateway restart, after IP change) and device-validation.md DV-P9.

## Completion and handoff

- [ ] Both cores pass every vector test; listed mutations fail.
- [ ] Contract requests (canonical bytes) answered by MP-N2 or the vectors.
- **Docs:** none user-facing (pairing docs are MP-N2-C9-T01).
- **Dependents:** MP-N1-C2-T05, MP-N1-C3-T02 (revocation input), MP-N1-C4-T02 (token for
  session bootstrap), MP-N7-C1-T02/T03 (brokers), MP-N4-C4-T05 (push registration rides on claim).
