---
ticket_id: MP-N2-C5-T01
feature_id: MP-N2
chunk_id: MP-N2-C5
bucket: 3-mobile-watch
title: "Pairing secret issuance, signed `aiur-pair:v1` QR URI and `aiur mobile qr` terminal rendering"
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C1-T01, MP-N2-C1-T02, MP-N2-C3-T02, MP-N2-C4-T01, MP-N2-C10-T02]
prior_units: [U1, U9]
prior_boundaries: [CLI, K]
prior_features: [MP-R1]
prior_findings: []
size_owner: "n/a (new modules under src/lib/aiur/machine/); launcher dispatch lines shared with U1/U9 — recheck at the implementation SHA"
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C5-T01 — QR builder, signer and terminal QR

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C5 "Pairing protocol".
- **User value:** the operator runs one command and gets a QR code the phone can scan to pair
  with this machine. The code is short-lived, single-use, signed, and only lists endpoints the
  phone can actually use.
- **Deliverable:**
  1. `Aiur.Machine.Pairing.issue/1` (PROPOSED): creates a 32-byte pairing secret, stores only
     `sha256(secret)` with `expires_at` and `used: false` in `pairing.json` (contract §5), keeps at
     most 3 outstanding (issuing a 4th deletes the oldest), returns the secret once.
  2. `Aiur.Machine.QrUri.build/1` (PROPOSED): the `aiur-pair:v1?...` URI of contract §3, fields
     `m, n, e (repeated), k, s, x, [t], sig`, with `sig` = Ed25519 over the canonical field string.
  3. `aiur mobile qr [--json]`: prints the terminal QR (`EQRCode.render/1`), the machine label, the
     expiry time and age, and the endpoints; `--json` prints `{uri, expires_at}` for scripts and
     for the settings surfaces (MP-N2-C8).
- **Non-goals:** the claim endpoint (C5-T02), the web QR surfaces (C8), the phone scanner (C5-T06).

## Dependencies and blockers

- DESIGN-N2 (terminal copy, the refusal text, expiry display).
- MP-N2-C1-T01 (machine store, `machine_key`), MP-N2-C1-T02 (`pairing.json` rows and the lock),
  MP-N2-C3-T02 (`aiur mobile` dispatch), MP-N2-C4-T01 (the gateway must be running for claims;
  `qr` warns when it is not), MP-N2-C10-T02 (`Aiur.Machine.Endpoints.select/2`).
- Concurrent with: MP-N2-C5-T02..T05 once the field layout below is fixed.
- Dependents: MP-N2-C5-T02 (verifies secrets), MP-N2-C8-T01/T02 (reuse `--json`), MP-N2-C5-T06.

## Verified starting point (base `45a290e3`)

- No pairing, QR or machine key exists (MP-N2 plan "Not found"; `git grep -n -i "qr" 45a290e3 -- src/lib` has no QR code).
- `src/mix.exs` has no QR dependency. Toolchain: erlang 28, elixir 1.19.5-otp-28 (`mise.toml`).
  Ed25519 signing is available in OTP `:crypto` (`:crypto.sign(:eddsa, :none, msg, [priv, :ed25519])`).
- Launcher dispatch is a `case` in the engine main near `status`
  (`packaging/npm/aiur-cli/libexec/aiur-engine.sh:4110`, cited by MP-N2 chunks C3-T02).
- Contract: `contracts/pairing-and-instance-registry.md` §3 (QR fields, 10-minute expiry, max 3
  outstanding, no loopback endpoint, `t=` only under T-B), §5 (`pairing.json`), §8.1 rule 2.

External evidence (accessed 2026-10-06):

- `eqrcode` 0.2.1, released 2025-02-21, MIT, zero dependencies, 3.08 M downloads
  (<https://hex.pm/packages/eqrcode>). API: `encode/2` with error-correction `:l | :m | :q | :h`,
  `render/1` (terminal), `svg/2`, `png/2` (<https://eqrcode.hexdocs.pm/0.2.1/EQRCode.html>).

## Chosen design

**QR encoder: `eqrcode ~> 0.2.1`.** Rationale: zero transitive dependencies, MIT, wide use, and it
provides both the terminal renderer (this ticket) and SVG (MP-N2-C8). An in-repo encoder (Reed-
Solomon plus masking, about 600 lines) would exceed the ticket budget and carry its own
correctness risk. Error-correction level `:m`. The URI is about 400–480 characters with two
endpoints and `t=`; at level M this fits QR version ≤ 15, which phone cameras read from a terminal.

**Canonical signed string.** Fields in fixed order, each `key=value` with RFC 3986
percent-encoding, joined by `&`, exactly as they appear in the URI before `&sig=`:
`m, n, e…(in order), k, s, x, [t]`. `sig = base64url_nopad(Ed25519(machine_key, canonical))`, i.e. over the URI query string with `sig` removed, parameters in contract §3 order (contract §4.0, settled).
The phone verifies with `k` and then pins `k` (contract §3). The same canonicalisation is
published as test vectors (MP-N2-C5-T05).

**Endpoint list** comes only from `Endpoints.select/2` (MP-N2-C10-T02). On
`{:error, :no_device_endpoint, rejected}` the command prints each rejected endpoint and reason and
exits 4 without issuing a secret (so no secret is wasted).

**Secret lifecycle.** `issue/1` runs under the store lock (MP-N2-C1-T02): prune expired rows,
evict the oldest if 3 remain, append the new hash. TTL = `pairing.secret_ttl_seconds`
(default 600). The secret appears only in the URI, never in a log or the journal.

**Gateway state.** If the gateway is not running, `qr` still prints the code (the store is
written directly under the lock) and adds one line: "the gateway is not running; start it with
`aiur mobile gateway start` before scanning" (copy per DESIGN-N2).

Exit codes: 0 ok; 2 mobile disabled (`aiur mobile enable` first); 3 identity unavailable
(MP-N2-C1-T01); 4 no device endpoint; 5 store locked or corrupt.

## Implementation steps

1. Add `{:eqrcode, "~> 0.2.1"}` to `src/mix.exs`; update `src/mix.lock`; record the licence in any
   dependency inventory the repo keeps.
2. `src/lib/aiur/machine/pairing.ex`: `issue/1`, `prune/1`.
3. `src/lib/aiur/machine/qr_uri.ex`: `build/1`, `canonical/1`, `verify/2` (used by tests and by the
   reference client).
4. `src/lib/aiur/machine/cli.ex` (created by MP-N2-C3-T02): `qr/1` rendering.
5. Engine: `mobile qr` dispatch to the release eval path used by the other `aiur mobile` verbs.

About 200 production lines.

## Non-happy paths

| Case | Behaviour |
|---|---|
| Mobile disabled | Exit 2; no secret issued. |
| `identity.json` missing or corrupt (RC-01) | Exit 3, `identity_unavailable`; never regenerates. |
| No usable endpoint | Exit 4 with every rejection reason; no secret issued. |
| Fourth QR while three are outstanding | Oldest secret deleted; its QR now fails with `pair_secret_unknown`. |
| Clock jumps backwards | Expiry is evaluated by the gateway clock only; a far-future `x` is still checked against the stored `expires_at`. |
| Terminal too narrow | `--json` and the settings page are the fallback; the CLI prints the URI under the QR. |

## Compatibility and rollout

New verb and dependency only; nothing runs unless mobile is enabled. Rollback removes the verb;
outstanding secrets expire within 10 minutes.

## Verification

`src/test/aiur/machine/qr_uri_test.exs` and `src/test/aiur/machine/pairing_test.exs` (temp HOME/XDG):

1. `"qr uri round-trips and the signature verifies with k"`. *Fails without:* signing in `build/1`.
2. `"changing any field invalidates the signature"` (flip one byte in `e`, `x`, `t`). *Fails without:*
   covering that field in `canonical/1` (mutation: drop `e` from the canonical string).
3. `"t= appears only when the transport mode is self_signed"`.
4. `"loopback or rejected endpoints never appear"` (stub `Endpoints.select/2`).
5. `"no device endpoint issues no secret"` → `pairing.json` unchanged. *Fails without:* the ordering
   (select before issue).
6. `"a fourth secret evicts the oldest"`. *Fails without:* eviction.
7. `"only the secret hash is stored and the journal has no secret"` (grep the store files and
   journal for the base64url secret). *Fails without:* hashing.
8. `"render produces a non-empty terminal QR for a 480-char uri"` (`EQRCode.encode(uri, :m) |> EQRCode.render()` output captured).

```bash
env HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN \
  mise exec -- mix test test/aiur/machine/qr_uri_test.exs test/aiur/machine/pairing_test.exs
```

Manual: `aiurdev mobile qr` on a machine with T-A transport; scan with the phone camera app to
confirm the code is legible at the default terminal font size (the camera shows the URI).

## Completion and handoff

- [ ] Tests 1–8 pass; mutation checks recorded in the PR body.
- [ ] Docs: `website/docs-app/reference/cli.md` `aiur mobile qr [--json]` with exit codes;
      configuration reference `pairing.secret_ttl_seconds`.
- [ ] Test vectors for the canonical string handed to MP-N2-C5-T05.
- [ ] Dependents: MP-N2-C5-T02, MP-N2-C8-T01, MP-N2-C8-T02, MP-N2-C5-T06.
