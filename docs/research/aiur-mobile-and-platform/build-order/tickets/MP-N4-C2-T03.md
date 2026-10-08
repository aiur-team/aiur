---
ticket_id: MP-N4-C2-T03
feature_id: MP-N4
chunk_id: MP-N4-C2
bucket: 3-mobile-watch
title: Relay FCM HTTP v1 adapter — data-only messages, priority/ttl/collapse, error mapping
status: ready
blocked_by: [DESIGN-N4 (no-UI release), MP-N4-C2-T01]
prior_units: []
prior_boundaries: [relay service (separate deployable)]
prior_features: []
prior_findings: [E-F1, E-F2, E-F3, E-F4, E-F6]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C2-T03 — FCM adapter

## Identity and outcome

Bucket 3, MP-N4, chunk C2. Implement `AiurPushRelay.Provider.Fcm` (PROPOSED): a
**data-only** FCM HTTP v1 message per contract v2 §5 (`data = {s, k, v}`), with
`android.priority`, `android.ttl` and `android.collapse_key`, OAuth2 service-account auth,
and response mapping.

Non-goals: production Firebase project (OQ-N4-1); notification messages (forbidden by
contract: they display without decryption, E-F1).

## Dependencies and blockers

- MP-N4-C2-T01. DESIGN-N4 releases C2. Live test project in C7 (OQ-N4-1).

## Verified starting point

Firebase docs (accessed 2026-10-06):
- "Send a message using FCM HTTP v1 API" (firebase.google.com/docs/cloud-messaging/send/v1-api,
  last updated 2026-10-06): `POST https://fcm.googleapis.com/v1/projects/<PROJECT_ID>/messages:send`;
  OAuth scope `https://www.googleapis.com/auth/firebase.messaging`;
  `Authorization: Bearer <access token>`.
- ErrorCode reference (firebase.google.com/docs/reference/fcm/rest/v1/ErrorCode, last
  updated 2026-02-03): `UNREGISTERED` (HTTP 404) "App instance was unregistered from FCM";
  `QUOTA_EXCEEDED` (HTTP 429); `INVALID_ARGUMENT` (HTTP 400).
- Payload ≤ 4,096 bytes (E-F1); ttl 0–2,419,200 s (E-F3); at most four collapse keys
  stored per device (E-F2); high priority must lead to a visible notification (E-F4).
- Service-account JWT (RS256) → access token exchange: implementer signs with `jose`
  (`src/mix.lock` `jose 1.11.12`) and exchanges at the token URI in the service-account
  JSON (`token_uri` field); no Google SDK dependency.

## Chosen design

- Message: `{"message":{"token":push_token,"data":{"s":sealed,"k":kid,"v":"1"},
  "android":{"priority":"HIGH"|"NORMAL","ttl":"<ttl_s>s","collapse_key":C}}}`; `C` is
  `"a"` for Command streams and `"b"` otherwise. The relay cannot see the stream, so the
  daemon passes the choice: `push_class` gains no new value; instead the envelope's
  `collapse_token` is used for APNs and the relay derives `C` from `push_class`
  (`alert_high` → `"a"`, `alert_normal` → `"b"`). **Consequence:** a non-blocking
  Command (normal) shares key `b` with progress. Accepted: FCM's 4-key limit (E-F2) makes
  finer keys unsafe, and the app reconciles on open.
- No `notification` block ever (test asserts absence).
- Access token cache refreshed 5 minutes before expiry.
- Mapping: `200` → `:ok`; `404 UNREGISTERED` → `{:gone, "UNREGISTERED"}`;
  `429 QUOTA_EXCEEDED` → `{:retry, retry-after or 60 s}`; `5xx` → retry with backoff;
  `400 INVALID_ARGUMENT` → `{:error, …}` (code only in logs).
- Config by environment: `AIUR_RELAY_FCM_SERVICE_ACCOUNT_FILE` (0600 checked). Missing →
  FCM disabled; `platform: fcm` handle creation → `503 provider_unavailable`.

## Implementation steps

1. `lib/aiur_push_relay/provider/fcm.ex`, `fcm/auth.ex` (PROPOSED).
2. Recorded fakes for token exchange and send.
3. Register for `platform == "fcm"`.

## Non-happy paths

- Token exchange fails → `{:retry, …}`, `/healthz` `fcm: degraded`.
- Data payload over size → `{:error, :payload_too_large}` without calling Google.

## Compatibility and rollout

Env-configured. Self-builders supply their own Firebase project (MP-Q2 resolution).

## Verification

`packages/aiur-push-relay/test/provider/fcm_test.exs` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"sends data-only message with no notification block"` | JSON has `data`, lacks `notification` | add a notification block |
| `"alert_high uses HIGH and collapse key a"` | fields | constant NORMAL |
| `"ttl is formatted as seconds string"` | `"3600s"` | integer ttl |
| `"404 UNREGISTERED marks handle gone"` | `{:gone, _}` | retry |
| `"QUOTA_EXCEEDED retries later"` | `{:retry, ms}` | error |

Commands: `env -C packages/aiur-push-relay mise exec -- mix test test/provider/fcm_test.exs`.

## Completion and handoff

- [ ] Contract §5 FCM section and this mapping agree (update the contract if the
  collapse-key derivation note is not already there — it is a relay detail, recorded in
  contract §5 by this ticket's PR).
- Dependents: C2-T05, C7.
