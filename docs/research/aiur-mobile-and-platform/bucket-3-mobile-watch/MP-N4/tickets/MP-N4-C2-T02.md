---
ticket_id: MP-N4-C2-T02
feature_id: MP-N4
chunk_id: MP-N4-C2
bucket: 3-mobile-watch
title: Relay APNs adapter — token auth, HTTP/2, headers, error mapping
status: ready
blocked_by: [DESIGN-N4 (no-UI release), MP-N4-C2-T01]
prior_units: []
prior_boundaries: [relay service (separate deployable)]
prior_features: []
prior_findings: [E-A1, E-A2, E-A3, E-A6]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C2-T02 — APNs adapter

## Identity and outcome

Bucket 3, MP-N4, chunk C2. Implement `AiurPushRelay.Provider.Apns` (PROPOSED): builds the
APNs request of contract v2 §5 from a relay envelope and a handle row, sends it over
HTTP/2 with token-based auth, and maps responses to the Provider behaviour.

Non-goals: obtaining the production `.p8` key (OQ-N4-1); watch direct push specifics
(MP-N7 reuses this adapter with its own topic).

## Dependencies and blockers

- MP-N4-C2-T01 (behaviour, store). DESIGN-N4 releases C2. Sandbox testing against Apple
  happens in C7 with credentials from OQ-N4-1; this ticket uses recorded fakes only.

## Verified starting point

Apple documentation (accessed 2026-10-06 via developer.apple.com/tutorials/data/…json):

- Servers: `https://api.sandbox.push.apple.com:443` (development) and
  `https://api.push.apple.com:443` (production); request is HTTP/2 `POST` with
  `:path = /3/device/<device token>` (example in "Sending notification requests to APNs").
- Headers: `apns-topic` required; `apns-push-type` (required for watchOS 6+, recommended
  otherwise); `apns-priority` 10/5/1; `apns-expiration`; `apns-collapse-id` ≤ 64 bytes
  (E-A2). Payload ≤ 4,096 bytes (E-A1).
- Responses ("Handling notification responses from APNs"): `400 BadDeviceToken`,
  `403 ExpiredProviderToken` ("the provider token is stale and a new token should be
  generated"), `410 Unregistered` / "The device token is no longer active for the topic",
  `429 TooManyRequests` (to the same device token).
- Token auth (E-A6): ES256 JWT signed with the team's `.p8` key, `kid` = key id,
  `iss` = team id, `iat`; refresh every 20–60 minutes.
- Libraries: `jose 1.11.12` (already vetted in `src/mix.lock`) signs ES256; HTTP/2 via
  Finch (`Finch` pool with `protocols: [:http2]`) — Req is built on Finch (`req ~> 0.7` in
  `src/mix.exs`).

## Chosen design

- Body: `{"aps":{"alert":{"title":F.title,"body":F.body},"mutable-content":1},
  "s":sealed,"k":kid,"v":1}` where `F` is the envelope's `fallback`.
- Headers: `apns-push-type: alert`; `apns-priority: 10` for `alert_high`, `5` for
  `alert_normal`; `apns-expiration = now + ttl_s` (unix seconds; `0` if `ttl_s == 0`);
  `apns-collapse-id = collapse_token`; `apns-topic = handle.app_topic`;
  host by `handle.environment`.
- JWT cache: one token per (team, key) refreshed at 40 minutes or on
  `403 ExpiredProviderToken` (single retry).
- Mapping: `200` → `:ok`; `410` or `400 BadDeviceToken` → `{:gone, reason}` (handle marked
  gone; daemon gets `410` on next send); `429` → `{:retry, 60_000}`; `5xx`/transport →
  `{:retry, backoff}`; other `4xx` → `{:error, reason}` logged by reason code only.
- Config by environment: `AIUR_RELAY_APNS_TEAM_ID`, `AIUR_RELAY_APNS_KEY_ID`,
  `AIUR_RELAY_APNS_KEY_FILE` (path to `.p8`, file mode checked 0600). Missing → APNs
  provider disabled; `/v1/handles` with `platform: apns` → `503 provider_unavailable`.

## Implementation steps

1. `lib/aiur_push_relay/provider/apns.ex`, `apns/jwt.ex`, `apns/request.ex` (PROPOSED).
2. Recorded-response fakes in `test/support/apns_fake.ex` (a Bandit HTTP/2 test server or
   a Finch adapter stub).
3. Wire into the provider registry by `handle.platform == "apns"`.

## Non-happy paths

- Key file unreadable/wrong mode → provider disabled, `/healthz` `apns: unavailable`.
- Token expired mid-flight → one refresh + retry, then `{:retry, …}`.
- Payload > 4,096 bytes (should be impossible given C1-T03) → `{:error, :payload_too_large}`
  without calling Apple.

## Compatibility and rollout

Env-configured; no change to T01 API. Production use waits for OQ-N4-1.

## Verification

`packages/aiur-push-relay/test/provider/apns_test.exs` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"builds alert push with fallback and sealed fields"` | body/headers exactly as above | omit `mutable-content` |
| `"high maps to priority 10, normal to 5"` | headers | constant 10 |
| `"410 Unregistered marks handle gone"` | `{:gone, "Unregistered"}` | map 410 to retry |
| `"BadDeviceToken marks handle gone"` | `{:gone, "BadDeviceToken"}` | treat as error |
| `"ExpiredProviderToken refreshes once"` | 2 requests, second with new JWT | no refresh |
| `"sandbox handle uses sandbox host"` | host check | single host |

Commands: `env -C packages/aiur-push-relay mise exec -- mix test test/provider/apns_test.exs`.

## Completion and handoff

- [ ] Fakes cover every mapped status. Sandbox run recorded in C7 (V-I1 etc.).
- Docs: env vars documented in the T05 operator page.
- Dependents: C2-T05, C7.
