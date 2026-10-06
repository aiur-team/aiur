---
ticket_id: MP-N2-C5-T02
feature_id: MP-N2
chunk_id: MP-N2-C5
bucket: 3-mobile-watch
title: "Gateway `POST /v1/pair/claim`: HMAC proof, single use, expiry, device limit and claim lockout"
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C5-T01, MP-N2-C1-T02, MP-N2-C1-T04, MP-N2-C4-T01, MP-N2-C4-T03]
prior_units: []
prior_boundaries: [K]
prior_features: [MP-N4]
prior_findings: []
size_owner: n/a (new gateway modules)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C5-T02 — Claim endpoint

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C5.
- **User value:** scanning the QR turns the phone into an authorized device of this machine in
  one request, and a stolen screenshot of an expired or used QR is worthless.
- **Deliverable:** `POST /v1/pair/claim` on the gateway per contract §4.1, with the proof format
  fixed below, the error codes, a device limit and a claim lockout.
- **Non-goals:** token issuance (C5-T03), relink (C5-T04), push registration semantics (MP-N4:
  the `push` object is stored opaquely).

## Dependencies and blockers

- DESIGN-N2 (error copy shown by the app; this ticket returns codes, not copy).
- MP-N2-C5-T01 (secrets in `pairing.json`), MP-N2-C1-T02 (device rows, lock), MP-N2-C1-T04
  (journal), MP-N2-C4-T01 (gateway endpoint), MP-N2-C4-T03 (signed JSON responses).
- Concurrent with: MP-N2-C5-T03, MP-N2-C5-T05.
- Dependents: MP-N2-C5-T03..T06, MP-N1-C2-T03 (device-side signing vectors), MP-N4-C4-T05 /
  MP-N4-C5 (push registration supplied at claim time).

## Verified starting point (base `45a290e3`)

- No gateway or claim route exists. The pattern for constant-time secret comparison is
  `AiurWeb.SupervisorAuth.token_matches?/2` (`src/lib/aiur_web/supervisor_auth.ex:78-82`:
  sha256 both sides, `Plug.Crypto.secure_compare/2`).
- `Aiur.Alerts.emit_system/2` (`src/lib/aiur/alerts.ex:103-106`) depends on the instance's
  workflow config, event exchange and ledger (`alerts.ex:9-13`); none of these run on the lean
  gateway node (MP-N2-C4-T01). So the lockout cannot write "through the existing alert ledger" as
  contract §4.1 says; see the contract request below.
- Contract §2 (device auth key P-256, non-exportable), §4.1, §5.

## Chosen design

**Proof format (contract §4.0, settled).** `secret_proof = base64url_nopad(HMAC-SHA256(secret,
JCS(body without "secret_proof")))`, where JCS is the RFC 8785 JSON Canonicalization Scheme
(<https://www.rfc-editor.org/rfc/rfc8785>, accessed 2026-10-06). The whole body — `machine_id`,
the `device` object (including `label`, `app_version`, `auth_public_key`, `parent_device_id`) and
`push` — is covered, so no field can be swapped in transit. The gateway re-serialises the
**received** JSON with its JCS implementation (PROPOSED `Aiur.Machine.Jcs`, about 80 lines: sorted
keys by UTF-16 code units, ECMAScript number formatting, minimal string escaping), never the
client's raw bytes. Integer-only numbers are expected; a non-integer number anywhere in the body is
rejected `invalid_body` to avoid ECMAScript float-formatting divergence across languages.

**Lookup.** The gateway cannot know which secret was used, so it computes the proof for each
outstanding, unexpired, unused secret (≤ 3) and compares in constant time. Exactly one match is
required.

**Validation order** (first failure wins; each is a typed 4xx):

1. `pairing_disabled` (403) when `mobile.enabled` is false.
2. Body shape: `auth_public_key` must decode as an SPKI for `id-ecPublicKey` on `secp256r1`
   (`:public_key.der_decode(:SubjectPublicKeyInfo, …)`); otherwise `invalid_device_key` (400).
   `platform ∈ {ios, android, watchos, wearos}`.
3. Lockout active → `pair_locked` (429) with `retry_after`.
4. No secret matches → `pair_secret_unknown` (401); counts toward lockout. If the proof matches an
   expired secret → `pair_secret_expired` (401); a used one → `pair_secret_used` (401).
5. `parent_device_id` given but unknown or revoked → `parent_unknown` (400).
6. Device count ≥ `pairing.max_devices` (default 20) → `device_limit` (409).
7. Success: under the store lock, mark the secret used, create the device row (`device_id` =
   16 random bytes, base32), store the `push` object opaquely, append `paired` to the journal, reply
   `201 {device_id, machine: {machine_id, machine_label, endpoints}, registered_at, sig}`.

**Lockout.** Five failed proofs (`pair_secret_unknown`) within 60 s lock claiming for 300 s. State
is in gateway memory plus a `claim_lockout` journal entry and an `aiur mobile status` line
("pairing locked until HH:MM, N failed attempts"). A gateway restart clears the in-memory window
(acceptable: an attacker still needs a valid secret, 2^256).

## Implementation steps

1. `src/lib/aiur/machine/claim.ex` (PROPOSED): `claim/2` pure over `(store, request, now)`.
2. Gateway controller route `POST /v1/pair/claim` (in the MP-N2-C4 router).
3. `Aiur.Machine.ClaimLockout` (PROPOSED, small GenServer in the gateway tree).
4. Status line in `aiur mobile status` (MP-N2-C3-T03 output).

About 220 production lines.

## Non-happy paths

| Case | Behaviour |
|---|---|
| Same QR scanned twice by one phone | The second claim gets `pair_secret_used`; the app (C5-T06) treats a known `machine_id` as a relink (C5-T04) before ever claiming. |
| Two phones race one secret | The store lock serialises; one 201, one `pair_secret_used`. |
| Claim over cleartext overlay | Allowed only if the endpoint was advertised (MP-N2-C10-T02); a passive observer sees the proof but not the secret, and the secret is single use. |
| Store corrupt | 503 `store_unavailable`; nothing written (fail closed, contract §9). |
| Push object larger than 4 KiB | `push_too_large` (400). |

## Compatibility and rollout

Gateway-only route; no instance changes. Contract version stays `aiur.machine/v1`; the proof
format change is made before any client ships.

## Verification

`src/test/aiur/machine/claim_test.exs` (pure, injected clock, temp store):

1. `"valid proof creates exactly one device row and marks the secret used"`. *Fails without:* the
   used flag (mutation: skip marking → test 2 fails too).
2. `"reusing a secret returns pair_secret_used"`.
3. `"expired secret returns pair_secret_expired"`. *Fails without:* the expiry check.
4. `"proof over a different public key is rejected"` (changes the SPKI hash). *Fails without:*
   covering the `device` object in the JCS input.
5. `"non-P-256 key is rejected with invalid_device_key"` (Ed25519 and P-384 SPKI fixtures).
6. `"five bad proofs in 60 s lock claims for 300 s, then unlock"`. *Fails without:* the lockout.
7. `"device_limit at max_devices"`. 8. `"unknown parent_device_id is rejected"`.
9. `"journal and logs never contain the secret or proof"` (capture_log + journal grep).
10. `"comparison is constant-time"` — asserted structurally: the module calls
    `Plug.Crypto.secure_compare/2` (a source-scan test, documented as a future-regression guard).

`src/test/aiur/machine/claim_endpoint_test.exs`: the route returns the contract JSON and status
codes and a `sig` verifiable with `machine_key.pub`.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/machine/claim_test.exs test/aiur/machine/claim_endpoint_test.exs
```

## Completion and handoff

- [ ] Tests pass with mutation checks recorded.
- [ ] Proof follows contract §4.0; CR-N2-2 (lockout alert path) applied to the contract by its owner.
- [ ] JCS conformance: the RFC 8785 Appendix examples are part of `jcs_test.exs`.
- [ ] Docs: the pairing guide (MP-N2-C9-T01) lists the error codes and what the app shows.
- [ ] Dependents: MP-N2-C5-T03, MP-N2-C5-T05 vectors, MP-N1-C2-T03.
