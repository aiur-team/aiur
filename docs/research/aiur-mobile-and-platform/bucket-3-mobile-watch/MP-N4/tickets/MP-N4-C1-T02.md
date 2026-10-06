---
ticket_id: MP-N4-C1-T02
feature_id: MP-N4
chunk_id: MP-N4-C1
bucket: 3-mobile-watch
title: HPKE base-mode seal and open on the daemon, proven by RFC 9180 vectors
status: ready
blocked_by: [DESIGN-N4 (no-UI release), MP-N4-C1-T01]
prior_units: []
prior_boundaries: [new #41 candidate push-relay]
prior_features: []
prior_findings: [E-C3, E-C4]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C1-T02 — HPKE seal/open (daemon)

## Identity and outcome

Bucket 3, MP-N4, chunk C1. Deliver `Aiur.Push.Crypto.Hpke` (PROPOSED,
`src/lib/aiur/push/crypto/hpke.ex`): RFC 9180 base mode, single-shot, suite
DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / ChaCha20-Poly1305 (ids 0x0020/0x0001/0x0003),
with `seal/4` and `open/5`. The daemon only seals; `open/5` exists for tests and for the
golden-vector generator (C1-T04).

Non-goals: framing, signing, sizes (C1-T03); other suites, PSK/auth modes, exporters.

## Dependencies and blockers

- MP-N4-C1-T01 (primitives module). DESIGN-N4 releases C1 (no UI).
- Concurrent with C1-T03 (independent module) and all of C2.

## Verified starting point

- `:crypto` functions used, all present on OTP 28 (MP-N4-C1-T01 evidence):
  `:crypto.generate_key(:eddh, :x25519)` / `(…, priv)`,
  `:crypto.compute_key(:eddh, peer_pub, my_priv, :x25519)`,
  `:crypto.mac(:hmac, :sha256, key, data)`,
  `:crypto.crypto_one_time_aead(:chacha20_poly1305, key, nonce, data, aad, true | tag, false)`.
- No HPKE code exists in the repo (`git grep -n -i hpke 45a290e3 -- src` is empty).
- Vectors: RFC 9180 Appendix A.2.1 (rfc-editor.org/rfc/rfc9180, accessed 2026-10-06).
  The Phase C probe reproduced `enc`, `shared_secret`, `key_schedule_context`, `key`,
  `base_nonce` and the sequence-0 ciphertext with exactly the algorithm below.

## Chosen design

```elixir
@spec seal(recipient_pub :: <<_::256>>, info :: binary(), aad :: binary(), pt :: binary(),
           opts :: keyword()) :: {enc :: <<_::256>>, ct :: binary()}
@spec open(enc :: <<_::256>>, recipient_priv :: <<_::256>>, info :: binary(),
           aad :: binary(), ct :: binary()) :: {:ok, binary()} | {:error, :open_failed}
```

Algorithm (RFC 9180 §4.1, §5.1, §7.1; suite ids above):

- `LabeledExtract(suite, salt, label, ikm) = HMAC(salt, "HPKE-v1" ‖ suite ‖ label ‖ ikm)`.
- `LabeledExpand(suite, prk, label, info, L) = HKDF-Expand(prk, I2OSP(L,2) ‖ "HPKE-v1" ‖
  suite ‖ label ‖ info, L)`.
- KEM suite id `"KEM" ‖ 0x0020`; HPKE suite id `"HPKE" ‖ 0x0020 ‖ 0x0001 ‖ 0x0003`.
- Encap: ephemeral X25519 pair; `dh = X25519(skE, pkR)`; `kem_context = pkE ‖ pkR`;
  `shared = LabeledExpand(KEM, LabeledExtract(KEM, "", "eae_prk", dh), "shared_secret",
  kem_context, 32)`.
- Key schedule mode 0: `ksc = 0x00 ‖ LabeledExtract(HPKE,"","psk_id_hash","") ‖
  LabeledExtract(HPKE,"","info_hash",info)`; `secret = LabeledExtract(HPKE, shared,
  "secret", "")`; `key = LabeledExpand(HPKE, secret, "key", ksc, 32)`;
  `nonce = LabeledExpand(HPKE, secret, "base_nonce", ksc, 12)`.
- Seal: `ct = AEAD(key, nonce, aad, pt) ‖ tag(16)`. Open: reverse; any failure →
  `{:error, :open_failed}` (one atom; no oracle on which step failed).
- `opts[:ephemeral_private]` exists **only** for vector tests; production calls never
  pass it. A test asserts two seals of the same input give different `enc`.
- Reject an all-zero DH output (RFC 9180 §7.1.4 / X25519 small-order points) with
  `{:error, :open_failed}` on open and a raise on seal (programmer error: bad key).

## Implementation steps

1. `src/lib/aiur/push/crypto/hkdf.ex` (PROPOSED): `extract/2`, `expand/3` (≤ 255 blocks).
2. `src/lib/aiur/push/crypto/hpke.ex` (PROPOSED): the functions above, private labeled
   helpers, `@spec`s.
3. Vector fixture `src/test/support/fixtures/push/rfc9180_a21.json` (PROPOSED) holding the
   A.2.1 base values (copied from the RFC, with the RFC section cited in a `source` key).
4. Tests below.

## Non-happy paths

- Wrong recipient key, flipped ciphertext byte, wrong AAD or info → `{:error, :open_failed}`.
- Malformed lengths (enc ≠ 32 bytes) → `{:error, :open_failed}`, never a raise from
  `open/5` (the NSE equivalent must not crash either; mirrored in C4/C5).
- Small-order peer key → all-zero DH → rejected as above.

## Compatibility and rollout

New modules only; no config. Rollback = revert.

## Verification

`src/test/aiur/push/crypto/hpke_test.exs` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"reproduces RFC 9180 A.2.1 key schedule"` | `key`, `base_nonce`, `shared_secret` equal the fixture | change `"eae_prk"` label or drop `ksc`'s mode byte |
| `"reproduces RFC 9180 A.2.1 sequence 0 ciphertext"` | `ct` equals fixture `ct` | use `aad = ""` in seal |
| `"seal then open round-trips"` (StreamData property, 200 runs, pt 0..2600 bytes) | `{:ok, pt}` | swap key/nonce in open |
| `"any single byte flip fails to open"` (property over enc/ct positions) | `{:error, :open_failed}` | ignore tag on open |
| `"different aad fails"` | `{:error, :open_failed}` | drop `aad` from AEAD call |
| `"fresh ephemeral per seal"` | two `enc` differ | cache the ephemeral key |
| `"all-zero DH rejected"` | small-order point (RFC 7748 §6.1 list) → error | remove the zero check |

`stream_data ~> 1.2` is already a test dep (`src/mix.exs`).

Commands (from `src/`): `mise exec -- mix test test/aiur/push/crypto/hpke_test.exs`,
`mise exec -- mix format --check-formatted`, `mise exec -- mix lint`,
`mise exec -- mix dialyzer`.

## Completion and handoff

- [ ] All vector tests pass; mutation results named in the PR body.
- [ ] No production caller passes `:ephemeral_private` (grep test in C1-T03's suite).
- Docs: none. Dependents: C1-T03, C1-T04, C3-T03; native cores N1-C2-T3 use the same
  vectors through C1-T04.
