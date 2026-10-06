---
ticket_id: MP-N2-C5-T04
feature_id: MP-N2
chunk_id: MP-N2-C5
bucket: 3-mobile-watch
title: "`GET /v1/machine` endpoint refresh and `POST /v1/pair/relink` for a known machine"
status: blocked
blocked_by: [DESIGN-N2, MP-N2-C5-T02, MP-N2-C5-T03, MP-N2-C10-T02]
prior_units: []
prior_boundaries: [K]
prior_features: []
prior_findings: []
size_owner: n/a (new gateway modules)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N2-C5-T04 — Machine info and relink

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N2 / MP-N2-C5.
- **User value:** when the machine's address, label or certificate pin changes, the phone follows
  without pairing again; if the phone loses every address, re-scanning the QR repairs it without
  creating a second device entry.
- **Deliverable:** `GET /v1/machine` (token) and `POST /v1/pair/relink` per contract §4.3, plus the
  T-B pin fields (`tls_spki_sha256`, `_next`) when that transport is active.
- **Non-goals:** the app's relink UX (C5-T06), endpoint selection logic (MP-N2-C10-T02).

## Dependencies and blockers

DESIGN-N2; MP-N2-C5-T02 (proof format), MP-N2-C5-T03 (token), MP-N2-C10-T02 (`Endpoints.select/2`).
Concurrent with MP-N2-C6. Dependents: MP-N2-C5-T06, MP-N2-C9-T02 (row "IP change / relink").

## Verified starting point (base `45a290e3`)

Nothing exists. Contract §3 ("A QR whose `machine_id` the device already knows is a re-link"),
§4.3 (as updated with the T-B pin rule), §8.1.

## Chosen design

- `GET /v1/machine` → `{contract, machine_id, machine_label, endpoints, transport: {mode},
  tls_spki_sha256?, tls_spki_sha256_next?, observed_at, sig}`; `sig` is Ed25519 over the canonical
  JSON produced by the gateway's signing helper (MP-N2-C4-T03). Bumps `last_seen_at`.
- `POST /v1/pair/relink {machine_id, device_id, secret_proof}`: `secret_proof` uses the claim
  format of MP-N2-C5-T02 (HMAC over the RFC 8785 JCS of the relink body without `secret_proof`,
  contract §4.0). The relink body `{machine_id, device_id}` differs in shape from a claim body, so a
  claim proof never verifies as a relink proof. It consumes the secret. Success: `200 {device_id, machine}`;
  the device row is kept (no new row). Errors: the claim set plus `device_revoked` (row missing).
- A relink never changes the device's auth key. A phone that lost its key must revoke and pair
  again (the key is non-exportable; a new key means a new device).

## Implementation steps

1. `src/lib/aiur/machine/relink.ex` (PROPOSED) reusing `Claim` validation helpers.
2. `MachineController.show/2` and `relink/2` in the gateway router. About 120 production lines.

## Non-happy paths

| Case | Behaviour |
|---|---|
| Relink with a revoked `device_id` | `device_revoked`; the app offers a fresh pairing (claim) with the same QR only if the secret was not consumed — so the app must claim, not relink, after `device_revoked` (C5-T06). |
| QR from a different machine with the same label | `machine_id` differs → a new pairing, never a relink. |
| Signed response with a different key than pinned | Client hard error (contract §3); server cannot detect it. |
| Endpoint list empty (all rejected) | `endpoints: []` plus `transport.mode`; the app shows the "no reachable endpoint" state. |

## Compatibility and rollout

Gateway-only.

## Verification

`src/test/aiur/machine/relink_test.exs`:

1. `"relink keeps the same device row and consumes the secret"`. *Fails without:* reuse of the row
   (mutation: call `claim/2` instead → a second row appears, test fails).
2. `"a claim proof replayed to relink is rejected"`. *Fails without:* computing the HMAC over the relink body.
3. `"relink of a revoked device returns device_revoked"`.
4. `"machine response includes tls pins only in self_signed mode and is signed"`.
5. `"machine response endpoints equal Endpoints.select/2 output"` (stubbed).

```bash
env HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN \
  mise exec -- mix test test/aiur/machine/relink_test.exs
```

## Completion and handoff

- [ ] Tests pass; mutation checks recorded.
- [ ] Docs: pairing guide "the address changed" section (MP-N2-C9-T01).
- [ ] Dependents: MP-N2-C5-T06, MP-N2-C9-T02.
