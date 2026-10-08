---
ticket_id: MP-N4-C1-T04
feature_id: MP-N4
chunk_id: MP-N4-C1
bucket: 3-mobile-watch
title: nid and collapse_token derivation plus the cross-platform golden vector file
status: ready
blocked_by: [DESIGN-N4 (no-UI release), MP-N4-C1-T03, MP-R1-C3-T06 (aiur-contracts package home)]
prior_units: []
prior_boundaries: [new #41 candidate push-relay]
prior_features: [MP-R1, MP-N1]
prior_findings: [E-A2 (collapse-id ≤ 64 bytes), E-F2]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C1-T04 — Identity derivation and golden vectors

## Identity and outcome

Bucket 3, MP-N4, chunk C1. Deliver:

1. `Aiur.Push.Ids` (PROPOSED, `src/lib/aiur/push/ids.ex`): `nid/2` and
   `collapse_token/2` per contract v2 §6 (domain-separated HMAC-SHA256 with the device's
   `device_push_secret`; lowercase unpadded base32 first 26 chars; unpadded base64url
   first 32 chars).
2. A deterministic vector generator `mix aiur.push.vectors` (PROPOSED,
   `src/lib/mix/tasks/aiur.push.vectors.ex`) that writes
   `packages/aiur-contracts/push/v1/vectors.json` (PROPOSED path; package home from
   MP-R1-C3).
3. The committed vectors file, consumed by Swift and Kotlin tests (N1-C2-T03, MP-N4-C4-T02,
   MP-N4-C5-T02) and by the daemon test suite.

Non-goals: native implementations.

## Dependencies and blockers

- MP-N4-C1-T03 (seal/open). MP-R1-C3-T06 creates `packages/aiur-contracts`; if it lags, write
  the file to `src/test/support/fixtures/push/v1/vectors.json` (PROPOSED) and move it in
  C3-T00; the native suites read whatever single path C3-T00 fixes.
- DESIGN-N4 releases C1.

## Verified starting point

- Base32: Elixir `Base.encode32/2` with `case: :lower, padding: false` (stdlib).
- No `packages/aiur-contracts` at `45a290e3` (`git ls-tree -d 45a290e3 packages/` lists
  only `aiur-style`, `streamdeck`).
- Mix tasks live under `src/lib/mix/tasks/` (e.g. `aiur.env.example.ex`,
  `aiur.cost_report.ex` at `45a290e3`).

## Chosen design

Vector file schema (`"schema": "aiur.push.vectors/1"`):

```json
{ "schema": "aiur.push.vectors/1", "suite": "X25519-HKDF-SHA256-ChaCha20Poly1305",
  "rfc9180_a21": { … copied RFC values … },
  "cases": [ { "name": "command_needs_you_basic",
      "device": { "device_id": "…", "kid": "k_…", "x25519_priv": "hex", "x25519_pub": "hex",
                  "device_push_secret": "hex" },
      "machine": { "machine_id": "…", "ed25519_priv": "hex", "ed25519_pub": "hex" },
      "intent_id": "ni_…", "stream": "cmd:8f2c4e1a9b3d7f60",
      "expect": { "nid": "n_…", "collapse_token": "…",
                  "info_hex": "…", "ephemeral_priv": "hex", "payload_utf8": "…", "frame_hex": "…",
                  "sealed_b64url": "…" },
      "verdict": "accept" } ] }
```

Cases (each with `verdict` the device must reach): accept basic; accept at the 2,400-byte
cap; accept multibyte summary; reject wrong machine key; reject flipped ciphertext byte;
reject kid relabel; reject unknown frame version `0x02`; reject `v: 2`; reject expired
(fixed clock `now` in the case); reject `destination.machine_id` mismatch with the kid's
machine; reject `instance_id` not prefixed by `machine_id`; replay (same `nid` twice:
second is `reject_seen`). Fixed keys and ephemeral keys make every byte deterministic.

## Implementation steps

1. `ids.ex`: `nid(device_push_secret, intent_id)`,
   `collapse_token(device_push_secret, stream)`.
2. Mix task: builds every case from fixed inputs using C1-T02/T03 with
   `:ephemeral_private`; `--check` mode recomputes and diffs against the committed file
   (CI-friendly, no network).
3. Commit the generated file; add a daemon test that runs the `--check` logic.

## Non-happy paths

- Vector drift (someone changes the encoder): `--check` fails in CI with the case name.
- A native suite disagrees: that suite fails, not the daemon's (each side tests against
  the file, never against the other side).

## Compatibility and rollout

The file is versioned by `schema`; additive cases keep `/1`. Rollback = revert.

## Verification

`src/test/aiur/push/ids_test.exs`, `src/test/aiur/push/vectors_test.exs` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"nid is stable across retries and differs per device"` | same input → same nid; other secret → other nid | use `intent_id` directly |
| `"nid uses the nid domain label"` | equals hand-computed HMAC over `"nid\0" ‖ intent_id` | drop the label |
| `"collapse_token fits APNs 64-byte limit"` | 32 chars | take 80 chars |
| `"committed vectors match the generator"` | `--check` passes | change the frame version byte |
| `"every reject case is rejected by Seal.open plus device rules"` | each `verdict` reproduced by a reference acceptance function in test support | accept on bad signature |

The reference acceptance function in test support mirrors contract §4/§6 device rules so
the daemon proves each vector's verdict is reachable; native C4-T02/C5-T02 implement the
real one.

Commands (from `src/`): `mise exec -- mix test test/aiur/push/ids_test.exs
test/aiur/push/vectors_test.exs`, `mise exec -- mix aiur.push.vectors --check`.

## Completion and handoff

- [ ] Vectors committed at one path; README line in `packages/aiur-contracts` (or the
  fixtures dir) explains regeneration.
- Docs: none user-facing. Dependents: N1-C2-T03, MP-N4-C4-T02, MP-N4-C5-T02, C3-T03.
