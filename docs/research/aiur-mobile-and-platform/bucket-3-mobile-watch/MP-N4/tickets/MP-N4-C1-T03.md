---
ticket_id: MP-N4-C1-T03
feature_id: MP-N4
chunk_id: MP-N4-C1
bucket: 3-mobile-watch
title: ProtectedPayload encoder, size budget, inner frame and detached Ed25519 signature
status: ready
blocked_by: [DESIGN-N4 (no-UI release), MP-N4-C1-T02, MP-N2-C1-T1]
prior_units: []
prior_boundaries: [new #41 candidate push-relay]
prior_features: [MP-N2]
prior_findings: [E-A1, E-F1]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C1-T03 — Payload encoder, frame and signature

## Identity and outcome

Bucket 3, MP-N4, chunk C1. Deliver `Aiur.Push.Payload` (PROPOSED,
`src/lib/aiur/push/payload.ex`) and `Aiur.Push.Seal` (PROPOSED, `src/lib/aiur/push/seal.ex`):

1. `Payload.encode(intent, device) -> {:ok, json_bytes} | {:error, reason}` — builds the
   ProtectedPayload v1 JSON of contract §3 for one device (with that device's `nid`,
   C1-T04), enforcing the caps and truncation order.
2. `Seal.seal(json_bytes, device_key, signer) -> {:ok, %{kid, sealed}}` — builds the inner
   frame (`0x01 ‖ sig(64) ‖ payload`) with the detached signature over
   `"aiur-push-v1-sig" ‖ 0x00 ‖ info ‖ payload`, then HPKE-seals it (C1-T02) with
   `info = "aiur-push-v1" ‖ 0x00 ‖ device_id ‖ 0x00 ‖ kid` and empty AAD (contract v2 §4:
   Tink's public API binds only `info`). `sealed = enc ‖ ct ‖ tag`.
3. `Seal.open/3` for tests and the vector generator.

Non-goals: who signs (the signer is a function supplied by C3, backed by the MP-N2 store;
see CR-N4-2), relay envelope (C3-T03).

## Dependencies and blockers

- MP-N4-C1-T02 (HPKE). MP-N2-C1-T1 defines the machine key format (Ed25519 raw, 0600);
  this ticket only needs a `signer :: (binary() -> <<_::512>>)` and the public key, so it
  can be built with a test key before N2 lands; the integration is C3-T03.
- DESIGN-N4 releases C1. DESIGN-E2 §4.1 decides the title fallback when `short_label` is
  missing; this ticket only enforces the 40-char cap and rejects an empty title (the
  caller, N5, supplies the text), so it is not blocked by that decision.

## Verified starting point

- Contract v2 §3 (payload fields, caps), §4 (frame, AAD, info, signed message), §11.
- Ed25519 on OTP 28: `:crypto.sign(:eddsa, :none, msg, [priv, :ed25519])` and
  `:crypto.verify(:eddsa, :none, msg, sig, [pub, :ed25519])` (RFC 8032 TEST 1 reproduced,
  E-C4).
- JSON: `jason ~> 1.4` is a runtime dep (`src/mix.exs`). Map key order does not matter
  because the signature covers the exact bytes produced here (no canonicalization).
- Source fields: `Aiur.Decision` has `context.short_summary`, `urgency`, `blocking`
  (`src/lib/aiur/decision.ex:18-42,120-136`); N5 maps them into the intent.

## Chosen design

- Caps (bytes of UTF-8, measured after encoding): `summary.title` ≤ 40 **characters**
  (grapheme count via `String.length/1`), `subtitle` ≤ 60, `body` ≤ 160; whole JSON
  ≤ 2,400 bytes.
- Truncation order when over 2,400 bytes: shorten `body` (drop to `nil` if needed), then
  `subtitle`, cutting on a grapheme boundary and appending `…`. Never touch `title`,
  `destination`, ids. Still over → `{:error, :payload_too_large}` (logged with
  `intent_id` only, never text).
- No floats anywhere: encoder raises on a float in the intent (all numbers in the schema
  are integers).
- Field order in the JSON is fixed by building an ordered list (`Jason.OrderedObject`) so
  vectors are stable byte-for-byte across Elixir versions.
- `Seal` validates `kid` (`k_` + 26 base32 chars) and `device_id` before sealing.

## Implementation steps

1. `payload.ex`: `encode/2`, private `fit/1` (truncation), `@spec`s.
2. `seal.ex`: `info/2`, `signed_message/2`, `seal/3`, `open/3` (returns
   `{:ok, payload_bytes}` only after signature verification; else `{:error, reason}` with
   reason ∈ `:open_failed | :bad_frame | :bad_signature`).
3. Tests and fixtures.

## Non-happy paths

- Oversize after truncation → explicit error; C3 records `outcome: encode_failed` for that
  `(intent, device)` and never sends a partial payload.
- Non-UTF-8 text from an agent-supplied label → replaced by `�` (`:unicode` normalization)
  before measuring; never crash.
- Signer unavailable (store unreadable) → `{:error, :signer_unavailable}`; C3 maps it to
  `push: degraded`.

## Compatibility and rollout

New modules; payload `v: 1`, frame version `0x01`. A future frame version is additive; the
devices reject unknown versions with the fallback (contract §10).

## Verification

`src/test/aiur/push/payload_test.exs` and `src/test/aiur/push/seal_test.exs` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"truncates body first, then subtitle"` (fixture with 2,000-char body) | body shortened, title/destination intact, size ≤ 2,400 | truncate title first |
| `"over budget after truncation is an error"` (huge destination ids) | `{:error, :payload_too_large}` | return the oversized bytes |
| `"title over 40 characters is cut by graphemes"` (emoji fixture) | 40 graphemes + `…` rule per cap | byte-based cut |
| `"floats are rejected"` | raises `ArgumentError` | remove the guard |
| `"sealed size stays under the provider cap"` (2,400-byte payload) | `byte_size(Base.url_encode64(sealed, padding: false)) <= 3_351` | add a field to the frame |
| `"open verifies the signature over the exact bytes"` | tamper one payload byte before sealing with a different signer → `{:error, :bad_signature}` | skip verify in `open/3` |
| `"blob for device A does not open as device B"` | same payload sealed for A, opened with B's key or B's device_id → error | drop `device_id` from `info` (the cross-device replay test the chunk names) |
| `"signature binds kid"` | re-label kid in `info` on open → error | omit `kid` from signed message |
| `"AAD is empty so Tink-style open succeeds"` | `Hpke.open(enc, priv, info, "", ct)` → ok | pass a non-empty AAD in `seal/3` |
| `"no summary text in logs on failure"` | `capture_log` contains `intent_id`, not the title | log the payload |

Commands (from `src/`): `mise exec -- mix test test/aiur/push/payload_test.exs
test/aiur/push/seal_test.exs`, `mise exec -- mix lint`, `mise exec -- mix dialyzer`.

## Completion and handoff

- [ ] Contract v2 §3/§4 implemented exactly; any deviation goes back into the contract
  first.
- [ ] PR names the failing-without hunk per test.
- Docs: none. Dependents: C1-T04 (vectors), C3-T03 (fan-out), N1-C2-T3 (native open).
