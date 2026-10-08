---
ticket_id: MP-N2-C4-T03
feature_id: MP-N2
chunk_id: MP-N2-C4
bucket: 3-mobile-watch
title: Gateway device-token plug, signed versioned JSON responses (machine_key), and GET /v1/machine
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C4-T01, MP-N2-C1-T03, MP-N2-C1-T01]
prior_units: []
prior_boundaries: [WEB]
prior_features: [MP-N1]
prior_findings: [security m6 (domain-tagged sign/2)]
size_owner: n/a (new modules)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C4-T03 — Gateway auth plug and signed responses

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C4.
- **User value:** a phone can prove a response came from the machine it paired with ("this is not the
  machine you paired" is a hard error, contract §3), and only paired devices can read the gateway.
- **Deliverable:**
  - `Aiur.Machine.Gateway.DeviceAuth` plug: `Authorization: Bearer <token>` → `TokenVerifier.verify/1`
    (MP-N2-C1-T03) → `conn.assigns.device_id`; errors → `401 {"contract":"aiur.machine/v1","error":<reason>}`
    with `reason ∈ {device_revoked, token_expired, token_unknown, token_malformed, device_auth_disabled}`;
    `store_corrupt` → 503.
  - `Aiur.Machine.Gateway.Signed.json(conn, status, body)`: adds `contract: "aiur.machine/v1"`,
    `observed_at`, `machine_id`, then `sig` = base64url Ed25519 over the canonical JSON of the body
    without `sig` (`Store.sign(:registry, bytes)`, which prepends `"aiur-registry-v1\0"`;
    contract §4.0 and §5, security m6).
  - `GET /v1/machine` (token): `{machine_id, machine_label, endpoints[]}` signed (contract §4.3). The
    endpoint list comes from `Aiur.Machine.Endpoints.select/2` once MP-N2-C10-T02 lands; until then it is
    `gateway.endpoints` filtered of loopback (MP-N2-C10-T02 replaces the call).
  - `last_seen_at` flush: every 60 s the gateway writes accumulated `device_id → last_seen` from the
    verifier's ETS into the store (one locked write).
- **Non-goals:** token minting (MP-N2-C5-T03), registry (T04), TLS (C10-T02).

## Dependencies and blockers

DESIGN-N2 gate; MP-N2-C4-T01, MP-N2-C1-T03, MP-N2-C1-T01. Dependents: T04, MP-N2-C5-*, MP-N2-C7-*, MP-N1 native core (signature check).

## Verified starting point (base `45a290e3`)

- Bearer parsing and digest compare pattern: `src/lib/aiur_web/supervisor_auth.ex:61-82`; JSON error
  bodies with `www-authenticate` on 401 (`:84-90`).
- Ed25519 sign/verify in `crypto` (<https://www.erlang.org/doc/apps/crypto/crypto.html>, OTP 29.1.1 page,
  accessed 2026-10-06; available since OTP 24).
- Contract §4 ("Every response carries `contract: "aiur.machine/v1"`"), §4.2, §4.3, §9 (version skew).

## Chosen design

- **Canonical JSON for signing:** keys sorted lexicographically at every level, no insignificant
  whitespace, UTF-8, numbers as produced by `Jason` for integers only (the gateway emits no floats;
  timestamps are ISO-8601 strings). This is the subset of RFC 8785 (JCS,
  <https://www.rfc-editor.org/rfc/rfc8785>, accessed 2026-10-06) that integer-only payloads need;
  the client side (MP-N1-C2) implements the same subset against shared test vectors in
  `packages/aiur-mobile/fixtures/contract/` (this ticket produces the vectors).
- Signature covers `contract`, `machine_id` and `observed_at`, so a response cannot be replayed for a
  different machine; clients reject `observed_at` older than 5 minutes for `/v1/machine`.
- The plug never logs the token; it logs `device_id` (contract §2 rule 1).

## Implementation steps

1. `gateway/device_auth.ex`, `gateway/signed.ex`, `gateway/canonical_json.ex` (PROPOSED), router routes.
2. Test vectors: `test/fixtures/machine/signing_vectors.json` (body, canonical bytes, public key, sig),
   also copied to the mobile fixtures by MP-N1-C2. About 170 production lines.

## Non-happy paths

Mobile disabled after the gateway started → verifier returns `device_auth_disabled` (settings mtime
cache). Clock skew is not checked on tokens client-side (machine clock only, contract §9).

## Compatibility and rollout

New endpoints on a new process only.

## Verification

`src/test/aiur/machine/gateway_auth_test.exs` (Plug.Test against the router):

1. `"no bearer is 401 token_malformed"`; 2. `"revoked device is 401 device_revoked"` (after `Store.delete_device/1`, no restart).
   *Fails without:* the plug (mutation: skip plug for `/v1/machine` → fails).
3. `"every /v1 response has contract and a valid sig"` — verify with `machine_key.pub`.
   *Fails without:* signing (mutation: sign the body with a different key or skip sig → fails).
4. `"canonical json matches the shared vectors"` (`signing_vectors.json`; each vector records
   the domain-tagged bytes in hex).
4a. `"a registry signature does not verify as a QR signature"` (m6): verify the same body
   bytes with the `aiur-qr-v1\0` tag → false. *Fails without:* the purpose tag (mutation:
   sign untagged bytes for every purpose → both verify, row fails).
5. `"token never appears in logs"` (`capture_log` + grep).
6. `"last_seen flush writes once per minute"` (injected clock).

```bash
env -C src -u GITHUB_TOKEN -u GH_TOKEN HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" \
  mise exec -- mix test test/aiur/machine/gateway_auth_test.exs
```

## Completion and handoff

- [ ] Tests pass; mutation for 2, 3 recorded.
- [ ] Vectors handed to MP-N1-C2 (native-core signature verification).
- [ ] Docs: none user-facing (protocol described in the contract; the pairing guide describes behaviour).
