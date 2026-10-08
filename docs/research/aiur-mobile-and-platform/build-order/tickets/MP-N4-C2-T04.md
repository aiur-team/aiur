---
ticket_id: MP-N4-C2-T04
feature_id: MP-N4
chunk_id: MP-N4-C2
bucket: 3-mobile-watch
title: Relay abuse controls — per-handle rate limit, size checks, log retention
status: ready
blocked_by: [DESIGN-N4 (no-UI release), MP-N4-C2-T01]
prior_units: []
prior_boundaries: [relay service (separate deployable)]
prior_features: []
prior_findings: [contract §1 relay visibility; plan §7.6 stolen send_secret]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C2-T04 — Abuse controls

## Identity and outcome

Bucket 3, MP-N4, chunk C2. Bound the damage of a leaked `send_secret` or a misbehaving
daemon: per-handle token bucket (default 60/hour, burst 10), per-IP handle-creation limit
(default 20/hour), envelope size limits, and retention (send log ≤ 7 days, idempotency
rows ≤ 24 h). All limits are environment-configurable.

Non-goals: accounts, CAPTCHAs, payment. RQ-N4-7 (hosting cost and provider limits) is
measured in C7, not estimated here.

## Dependencies and blockers

- MP-N4-C2-T01. DESIGN-N4 releases C2.

## Verified starting point

- Contract v2 §8 (`429` with `retry_after_s`); plan §7.6 (stolen `send_secret` sends only
  sealed noise; rate-limited; rotate by re-registering).
- N5 policy caps non-Command notifications at 6 per instance per device per hour
  (MP-N5 plan §5.5), so 60/hour/handle leaves headroom for Commands and retractions.

## Chosen design

- Token bucket per handle in SQLite (`buckets(handle, tokens REAL, updated_at)`) — no
  floats leave the relay; persistence keeps limits across restarts.
- `POST /v1/send` over limit → `429 {"error":"rate_limited","retry_after_s":N}`; the
  idempotent replay of an already-accepted key does **not** consume a token.
- `POST /v1/handles` per source IP: 20/hour → `429`.
- Pruner every 10 minutes deletes `sends` > 24 h, `send_log` > 7 days.
- Env: `AIUR_RELAY_SEND_PER_HOUR`, `AIUR_RELAY_SEND_BURST`,
  `AIUR_RELAY_HANDLES_PER_IP_HOUR`, `AIUR_RELAY_LOG_RETENTION_DAYS` (max 7, refuse to
  start above 7 to keep the privacy promise in contract §8).

## Implementation steps

1. `lib/aiur_push_relay/rate_limit.ex`, `pruner.ex` (PROPOSED); plug into `send.ex` and
   `handles.ex`.
2. Injected clock for tests.

## Non-happy paths

- Clock jumps backwards → bucket treats negative elapsed as 0.
- DB unavailable → fail closed for sends (`503`), never unlimited.

## Compatibility and rollout

Defaults conservative; operator can raise. Daemon already handles `429` (C3-T03).

## Verification

`packages/aiur-push-relay/test/rate_limit_test.exs` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"11th burst send is 429 with retry_after_s"` | 10 × 202, then 429 | remove the bucket check |
| `"idempotent replay does not consume a token"` | replay of key 1 after 10 sends still 202 | consume before dedupe |
| `"retention above 7 days refuses to start"` | `{:error, :retention_too_long}` | accept any value |
| `"pruner removes rows older than limits"` | fixed-clock rows gone | no pruner |
| `"handle creation per IP is limited"` | 21st → 429 | no IP limit |

Commands: `env -C packages/aiur-push-relay mise exec -- mix test test/rate_limit_test.exs`.

## Completion and handoff

- [ ] Limits documented in the T05 operator page with defaults.
- Dependents: C2-T05.
