---
ticket_id: MP-N4-C1-T01
feature_id: MP-N4
chunk_id: MP-N4-C1
bucket: 3-mobile-watch
title: Pin the push crypto primitives to OTP 28 and add a runtime support guard
status: ready
blocked_by: [DESIGN-N4 (no-UI release), MP-N4-C3-T00]
prior_units: []
prior_boundaries: [new #41 candidate push-relay]
prior_features: []
prior_findings: [E-C4 (resolved in this ticket's research)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C1-T01 — Push crypto primitives on OTP 28 and a runtime guard

## Identity and outcome

Bucket 3, MP-N4, chunk C1. The research question RQ-N4-1 / E-C4 ("does the pinned
Erlang/OTP expose X25519, HMAC-SHA256 and ChaCha20-Poly1305?") is **resolved** (evidence
below). This ticket turns that answer into code: a tiny module that names the primitives
the push suite uses and checks, at runtime, that the linked libcrypto still provides
them.

Deliverable: `Aiur.Push.Crypto.Primitives` (PROPOSED,
`src/lib/aiur/push/crypto/primitives.ex`) with `supported?/0` and `missing/0`, plus the
evidence note in `platform-evidence.md` E-C4 (already written in Phase C).

Non-goals: HPKE itself (C1-T02), framing and signing (C1-T03), capability reporting
(C3-T04 consumes `missing/0`).

User value: push never fails silently on a host whose OpenSSL lacks a curve (FIPS mode
or an old libcrypto); the capability report says why.

## Dependencies and blockers

- DESIGN-N4: no user-visible change; DESIGN-N4's header releases C1–C3 before approval.
- MP-N4-C3-T00 (plan refresh) only fixes the final module path if MP-R1 has landed;
  if C1 starts before the refactor, use the pre-refactor path and let C3-T00 move it.
- No new Hex dependency (decision below). May run concurrently with every other ticket.

## Verified starting point

- Toolchain pin at `45a290e3`: `mise.toml` — `erlang = "28"`, `elixir = "1.19.5-otp-28"`.
  CI and release builds install through mise (`.github/workflows/release-npm.yml:190-199`,
  "matching the versions the rest of CI uses (mise.toml)"; `ci.yml:725-729`).
- `src/mix.exs:150` `extra_applications: [:logger]`; `:crypto` is already used at runtime:
  `src/lib/aiur_web/github_webhook/signature.ex:33` and
  `src/lib/aiur_web/financial_data_access/proof.ex:149` call `:crypto.mac(:hmac, :sha256, …)`.
  So `:crypto` is already in the release.
- Hex deps (`src/mix.exs` deps): `jose 1.11.12` is present but **not needed**.
- Evidence gathered in Phase C (accessed 2026-10-06), recorded in
  [platform-evidence.md](../platform-evidence.md) E-C4:
  - Local resolution of the pin: OTP 28.5, crypto 5.8.3, OpenSSL 3.6.3;
    `crypto:supports/1` lists `chacha20_poly1305`, `eddh`, `eddsa`, `x25519`, `ed25519`,
    `hmac`, `sha256`.
  - OTP 28 docs (erlang.org/docs/28/apps/crypto/crypto, crypto v5.8.3.3):
    `edwards_curve_dh() :: x25519 | x448`; `cipher_aead()` includes `chacha20_poly1305`;
    "this list might be reduced if the underlying libcrypto does not support all of
    them"; "some curves are disabled if FIPS is enabled".
  - erlang.org/docs/28/apps/crypto/algorithm_details.html: X25519 and EdDSA need OpenSSL
    ≥ 1.1.1; `chacha20_poly1305` needs ≥ 1.1.0.
  - `:crypto` has no HKDF function; HKDF is two HMAC calls (RFC 5869).
  - A scratch probe (not committed) reproduced RFC 9180 A.2.1 and RFC 8032 §7.1 TEST 1
    with `:crypto` only.

## Chosen design

Use Erlang `:crypto` directly; no Hex crypto dependency. Rationale: every primitive is
present on the pinned OTP; `jose` would add an indirection without adding HPKE.

```elixir
defmodule Aiur.Push.Crypto.Primitives do
  @required [{:public_keys, :eddh}, {:public_keys, :eddsa}, {:curves, :x25519},
             {:curves, :ed25519}, {:ciphers, :chacha20_poly1305}, {:macs, :hmac},
             {:hashs, :sha256}]
  @spec missing() :: [{atom(), atom()}]   # [] when all present
  @spec supported?() :: boolean()
end
```

`missing/0` reads `:crypto.supports(kind)` for each kind once and caches the result in
`:persistent_term` (libcrypto cannot change while the VM runs).

## Implementation steps

1. Add `src/lib/aiur/push/crypto/primitives.ex` (PROPOSED) with `@moduledoc` naming the
   suite and the evidence.
2. Implement `missing/0` and `supported?/0`; `@spec` on both (the `specs.check` gate).
3. Add the test file below.

## Non-happy paths

- FIPS mode or an old libcrypto drops `x25519`/`ed25519`: `missing/0` returns the gaps;
  C3-T04 reports `push: unavailable`, reason `dependency_unavailable`,
  `depends_on: ["runtime.crypto"]` (contract §4 runtime guard). Nothing crashes.
- `:crypto` fails to load at all: the daemon already fails today (webhook signatures);
  out of scope.

## Compatibility and rollout

New module, no config, no migration. Rollback = revert.

## Verification

File `src/test/aiur/push/crypto/primitives_test.exs` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `test "the pinned OTP provides every push primitive"` | `missing() == []` | the `:chacha20_poly1305` entry (remove it from `@required` and the test that asserts the list contains it fails) |
| `test "missing/0 reports a primitive the libcrypto lacks"` | with an injected supports function returning a list without `:x25519`, `missing()` contains `{:curves, :x25519}` | replace `missing/0` with `[]` |
| `test "supported?/0 is false when anything is missing"` | injected gap → `false` | hard-code `true` |

Inject the supports function through an optional argument (`missing(supports_fun)`),
not by mocking `:crypto`.

Commands (from `src/`): `mise exec -- mix test test/aiur/push/crypto/primitives_test.exs`,
`mise exec -- mix format --check-formatted`, `mise exec -- mix lint`.

## Completion and handoff

- [ ] Module and tests merged; E-C4 row in platform-evidence.md cites this ticket.
- [ ] PR body states each test fails with its production hunk reverted (AGENTS.md).
- Docs: none (internal).
- Dependents: MP-N4-C1-T02, C1-T03, C3-T04.
