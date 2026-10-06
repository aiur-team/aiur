---
ticket_id: MP-N2-C5-T05
feature_id: MP-N2
chunk_id: MP-N2-C5
bucket: 3-mobile-watch
title: "Reference device client (test harness) and cross-language pairing test vectors"
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C5-T01, MP-N2-C5-T02, MP-N2-C5-T03, MP-N2-C5-T04, MP-R1-C3-T06]
prior_units: []
prior_boundaries: [DEV]
prior_features: [MP-N1, MP-R1]
prior_findings: [security m6 (QR and registry vectors carry the domain tag)]
size_owner: n/a (test support and fixtures)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C5-T05 — Reference client and vectors

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C5.
- **User value:** the Swift and Kotlin device cores (MP-N1-C2) and the Elixir gateway agree on
  every byte of the pairing protocol before any phone build exists, so interop bugs surface in CI
  instead of on a device.
- **Deliverable:**
  1. `Aiur.Test.DeviceClient` (`src/test/support/device_client.ex`): scans a QR URI, verifies `sig`,
     claims, exchanges tokens, refreshes, relinks, calls `/v1/machine`, `/v1/instances`, and an
     instance route with the bearer; keeps its P-256 key in memory. Used by MP-N2 integration tests
     and by MP-N2-C6/C7 tests.
  2. Vectors in `packages/aiur-contracts/fixtures/pairing/v1/` (package created by MP-R1-C3-T06):
     `qr_uri.json` (fields, canonical string, Ed25519 key, expected sig), `claim_proof.json`,
     `relink_proof.json`, `token_signature.json` (fixed P-256 key, nonce, message, a valid DER
     signature, and negative cases: raw r‖s, wrong machine_id), `canonical_response.json`.
  3. A generator `mix aiur.pairing_vectors` (PROPOSED, `src/lib/mix/tasks/aiur.pairing_vectors.ex`)
     that regenerates the files deterministically from fixed seeds, and a test that fails if the
     committed files differ from the generator output.
- **Non-goals:** the app (MP-N1); push vectors (MP-N4-C1).

## Dependencies and blockers

DESIGN-N2; MP-N2-C5-T01..T04 (formats); MP-R1-C3-T06 (`packages/aiur-contracts`). If R1-C3-T06 has
not landed, the vectors live in `src/test/fixtures/pairing/v1/` and move with that ticket (one path
constant). Dependents: MP-N1-C2-T03 (Swift and Kotlin signing tests read these files), MP-N2-C6,
MP-N2-C7, MP-N2-C9-T02.

## Verified starting point (base `45a290e3`)

- `src/test/support/` exists for shared test helpers (`git ls-tree 45a290e3 src/test/support`).
- `packages/` holds standalone packages such as `packages/streamdeck` (MP-N1 plan F9); no
  `aiur-contracts` yet.
- Formats: MP-N2-C5-T01 (canonical QR string), C5-T02 (claim proof), C5-T03 (token message, DER),
  C5-T04 (relink prefix).

## Chosen design

- ECDSA signatures are randomised, so a vector carries one **valid** DER signature for
  verification tests, and the Swift/Kotlin tests check that (a) their implementation verifies it and
  (b) their own fresh signature verifies with the Elixir verifier through the reference fixture
  server (MP-N3-C5 fixture gateway may host it) — the cross-language check is "verify each other",
  not byte equality.
- Ed25519 and HMAC are deterministic, so those vectors are byte-exact.
- All signed bytes follow contract §4.0 (RFC 8785 JCS bodies without `secret_proof`/`sig`; QR query
  string minus `sig`; device message `nonce.device_id.machine_id`; base64url without padding).
  Machine signatures cover a domain tag plus those bytes (security m6): `aiur-qr-v1\0` for
  `qr_uri.json`, `aiur-registry-v1\0` for `canonical_response.json`. Device ECDSA and HMAC
  proofs are unchanged (they already bind `machine_id`). Each
  vector file records the exact canonical bytes (hex) next to the result, so a Swift or Kotlin JCS
  bug shows up as a byte diff, not only a failed verify. These vectors are authoritative for
  MP-N1-C2-T03.
- `jcs.json`: the RFC 8785 Appendix B examples plus aiur bodies with Unicode labels.
- Fixed seeds are test-only keys and are named `TEST ONLY` in the JSON.

## Implementation steps

1. `device_client.ex` (about 200 lines of test support).
2. Mix task and fixtures. 3. Drift test.

Production code: the mix task only (≈ 80 lines); it is excluded from the release.

## Non-happy paths

Negative vectors: tampered QR field, expired `x`, raw r‖s signature, wrong domain prefix
(a registry-tagged signature presented as a QR signature, and an untagged one), wrong curve key.
Each carries `expect: "reject"` and the error code.

## Compatibility and rollout

Fixtures are versioned by directory (`v1`). A format change adds `v2`; `v1` stays until no client
uses it.

## Verification

`src/test/aiur/machine/pairing_vectors_test.exs`:

1. `"committed vectors equal generator output"`. *Fails without:* regenerating after a format change.
2. `"every positive vector verifies and every negative vector is rejected with its code"`.
   *Fails without:* the gateway checks of C5-T01..T04 (this is their cross-check).

`src/test/aiur/machine/pairing_flow_integration_test.exs` (gateway started in-test, temp store):

3. `"device client pairs, gets a token, lists instances and relinks"` end to end.

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/machine/pairing_vectors_test.exs test/aiur/machine/pairing_flow_integration_test.exs
```

## Completion and handoff

- [ ] Tests pass; vectors committed under the chosen path.
- [ ] MP-N1-C2-T03 notified of the vector path and file names.
- [ ] Docs: none user-facing; a README in the fixtures directory names each file.
