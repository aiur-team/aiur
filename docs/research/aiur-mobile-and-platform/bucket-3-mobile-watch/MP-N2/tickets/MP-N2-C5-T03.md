---
ticket_id: MP-N2-C5-T03
feature_id: MP-N2
chunk_id: MP-N2-C5
bucket: 3-mobile-watch
title: "Gateway `/v1/token/challenge` and `/v1/token`: P-256 ECDSA proof of the device key, 15-minute access tokens"
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C5-T02, MP-N2-C1-T03]
prior_units: []
prior_boundaries: [K]
prior_features: []
prior_findings: []
size_owner: n/a (new gateway modules)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C5-T03 — Token exchange

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C5.
- **User value:** the phone gets a short-lived bearer for every gateway and instance request by
  proving possession of its hardware key; a leaked token expires in 15 minutes and a revoked device
  can never mint another.
- **Deliverable:** `POST /v1/token/challenge` and `POST /v1/token` per contract §4.2, storing only
  `sha256(token)` with expiry in the device row (verified by MP-N2-C1-T03 `verify_token/1`).
- **Non-goals:** the instance-side plug (MP-N2-C6-T01), relink (C5-T04).

## Dependencies and blockers

- DESIGN-N2 (gate; no UI). MP-N2-C5-T02 (device rows with `auth_public_key`), MP-N2-C1-T03
  (token-hash store and verification).
- Concurrent with: MP-N2-C5-T04, MP-N2-C6-T01.
- Dependents: every authenticated call; MP-N1-C2-T03 (device signing must match the vectors of
  MP-N2-C5-T05).

## Verified starting point (base `45a290e3`)

- No token exchange exists. OTP `:public_key` and `:crypto` are available (erlang 28, `mise.toml`).
- Contract §2: device auth key is P-256 in the Secure Enclave or Android Keystore.

External evidence (accessed 2026-10-06):

- Secure Enclave keys are NIST P-256 only and support signing
  (<https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave>).
  `SecKeyCreateSignature` with `.ecdsaSignatureMessageX962SHA256` produces an ANSI X9.62
  (DER) signature (<https://developer.apple.com/documentation/security/seckeyalgorithm/ecdsasignaturemessagex962sha256>).
- Android Keystore `SHA256withECDSA` signatures are DER-encoded ASN.1 (Java `Signature` standard
  names, <https://docs.oracle.com/en/java/javase/21/docs/specs/security/standard-names.html#signature-algorithms>).

## Chosen design

- **Challenge:** `{device_id}` → `{nonce: b64url(32 random bytes), expires_at: now+60s}`. Nonces are
  kept in gateway memory, keyed by `device_id`, at most 4 live per device (oldest evicted). Unknown or
  revoked `device_id` → `401 device_revoked` (no oracle difference between unknown and revoked).
- **Token:** `{device_id, nonce, signature}` where `signature = DER ECDSA-P256-SHA256` over
  the ASCII bytes `nonce "." device_id "." machine_id` (contract §4.0, settled; all three are base32/base64url, so `.` cannot occur inside them). Verify with
  `:public_key.verify(msg, :sha256, der_sig, {{:ECPoint, point}, {:namedCurve, :secp256r1}})`.
  The nonce is consumed on the first attempt, success or failure (no replay, no retry on one nonce).
- **Token value:** `"aiurd_" <> b64url(32 random bytes)`. The prefix lets log scanners and the
  MP-R3 census recognise it. Store `{sha256, expires_at = now+900s}`; keep at most 3 unexpired
  hashes per device (rolling refresh); prune expired on each write.
- Response: `{access_token, expires_at, machine_id, sig}`; update `last_seen_at`.
- All failures other than a revoked device return `401 token_proof_invalid`.

## Implementation steps

1. `src/lib/aiur/machine/token_exchange.ex` (PROPOSED): `challenge/2`, `exchange/3`.
2. `Aiur.Machine.NonceStore` (PROPOSED, ETS owned by a gateway process).
3. Routes in the gateway router. About 160 production lines.

## Non-happy paths

| Case | Behaviour |
|---|---|
| Replayed nonce | `token_proof_invalid`; the nonce was consumed. |
| Nonce older than 60 s | `token_proof_invalid`. |
| Device revoked between challenge and token | `device_revoked` (store re-read under the lock). |
| Gateway restart | Outstanding nonces are lost; the client requests a new challenge. Issued tokens survive (hashes on disk, contract §9). |
| Clock skew on the phone | Irrelevant: expiry is computed and checked on the machine. |
| Raw (r‖s) signature from a misimplemented client | Rejected; vectors in MP-N2-C5-T05 pin the DER format. |

## Compatibility and rollout

Gateway-only. No config.

## Verification

`src/test/aiur/machine/token_exchange_test.exs` (keys generated with
`:public_key.generate_key({:namedCurve, :secp256r1})`, injected clock):

1. `"valid signature over the nonce yields a token whose hash is stored"`. *Fails without:* the store write.
2. `"replayed nonce is rejected"`. *Fails without:* nonce consumption.
3. `"expired nonce is rejected"`. 4. `"signature by a different key is rejected"`.
5. `"signature binding: a signature over another machine_id is rejected"`. *Fails without:*
   `machine_id` in the message.
6. `"revoked device gets device_revoked from both endpoints"`.
7. `"only three live token hashes are kept per device"`.
8. `"token is never logged"` (capture_log grep for the token value).

```bash
env HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN \
  mise exec -- mix test test/aiur/machine/token_exchange_test.exs
```

## Completion and handoff

- [ ] Tests pass with mutation checks recorded.
- [ ] Message formats included in MP-N2-C5-T05 vectors.
- [ ] Message and DER encoding match contract §4.0 and the C5-T05 vectors.
- [ ] Dependents: MP-N2-C6-T01, MP-N1-C2-T03.
