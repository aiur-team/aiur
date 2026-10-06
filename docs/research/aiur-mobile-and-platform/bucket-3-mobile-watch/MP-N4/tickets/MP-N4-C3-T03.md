---
ticket_id: MP-N4-C3-T03
feature_id: MP-N4
chunk_id: MP-N4-C3
bucket: 3-mobile-watch
title: Fan-out and relay client — read device registry, seal per device, send, map responses
status: ready
blocked_by: [DESIGN-N4 (no-UI release), MP-N4-C3-T02, MP-N4-C1-T03, MP-N4-C1-T04, MP-N2-C1-T1, MP-N2-C1-T2]
prior_units: []
prior_boundaries: [new #41 candidate push-relay]
prior_features: [MP-N2]
prior_findings: [contract v2 §7, §8]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C3-T03 — Fan-out and relay client

## Identity and outcome

Bucket 3, MP-N4, chunk C3. Deliver `Aiur.Push.Sender` (PROPOSED,
`src/lib/aiur/push/sender.ex`) and `Aiur.Push.RelayClient` (PROPOSED). For each due outbox
job: load the device's `push_registration` from the MP-N2 machine store, encode and seal
the payload (C1-T03/T04), POST the relay envelope (contract v2 §8), and record the
outcome in the outbox. Mark a device `gone` on `404`/`410` and stop sending to it.

Non-goals: choosing audiences (MP-N5 passes device ids), deregistration (C3-T05).

## Dependencies and blockers

- C3-T02 (outbox), C1-T03 (seal), C1-T04 (ids), MP-N2-C1-T1/T2 (store library: read
  `devices.json`, `identity.json`).
- **CR-N4-2** (CONTRACT-REQUESTS.md): MP-N2-C1 exposes a read-only `sign/1` for instance
  daemons so the machine private key is never copied into push code. If MP-N2 declines,
  push-relay reads `machine_key` through the store library (same OS user, 0600) — the
  ticket stays implementable either way; only the signer function's source changes.
- DESIGN-N4 releases C3 core.

## Verified starting point

- Machine store layout (pairing contract §5): `devices.json` rows carry
  `push_registration` (opaque to MP-N2; contract v2 §7 defines it), `identity.json`,
  `machine_key` (Ed25519 raw, 0600). Instances read; the gateway is the single writer.
- HTTP client: `req ~> 0.7` (`src/mix.exs`; `req 0.7.2` in `mix.lock`).
- Response semantics: contract v2 §8 (`202`, `404 handle_unknown`, `410 handle_gone`,
  `429 retry_after_s`, `5xx`).

## Chosen design

- Registry read: `Aiur.Push.Registry.devices/0` (PROPOSED) wraps the MP-N2 store reader,
  caches by `devices.json` mtime, and returns only rows whose `push_registration` parses
  and whose `relay_url` passes the scheme rule (https, or loopback when
  `push.allow_loopback_relay`). Invalid rows are skipped and counted (C3-T04 reports
  `degraded` if any).
- Gone state: the daemon cannot write `devices.json` (gateway is the single writer), so
  `gone` is kept in `<runtime_state_dir>/push/device_state.json` (PROPOSED) keyed by
  `{device_id, handle}`; a new handle for the same device (re-registration) clears it.
- Per job: `kid` = newest key in `enc_keys`; `nid`, `collapse_token` from
  `device_push_secret`; envelope `{v:1, handle, push_class, ttl_s, collapse_token, sealed,
  kid, idempotency_key: nid, fallback}`; `push_class = alert_high` iff intent
  `urgency: high`; `ttl_s = max(0, expires_at - now)`; fallback from the release constant
  (DESIGN-N4 D-1 default `aiur` / `New notification`, replaceable at approval without code
  structure change).
- Concurrency: one `Task.Supervisor` child per job, max 4 in flight per instance; timeout
  `push.send_timeout_ms`.
- Response mapping → outbox outcome: `202` → `:sent`; `404`/`410` → `{:gone}` + device
  state; `429` → `{:retry, now + retry_after_s}`; `5xx`/timeout → `{:retry, backoff}`;
  `401` → `{:gone}` (the handle's secret no longer matches: re-registration needed) with a
  distinct log reason; other `4xx` → terminal `{:error, status}`.

## Implementation steps

1. `registry.ex`, `sender.ex`, `relay_client.ex`, `device_state.ex` (PROPOSED).
2. Wire `Outbox.next_due/1` → `Sender.deliver/1` → `Outbox.record/2`.
3. Signer injection: `Application` env `:push_signer` defaulting to the MP-N2 function.
4. Tests against a Bandit test relay (Plug router in `test/support/fake_relay.ex`).

## Non-happy paths

- No paired device / no registration → nothing sent; N5's intents for that device are not
  accepted (C3-T02 `accept/2` filters missing devices) — no backlog that bursts later.
- Store unreadable or corrupt → fail closed: send nothing, `push: degraded`
  (`dependency_unavailable`, `depends_on: ["pairing"]`).
- Device revoked between accept and send → registry miss → terminal `{:dropped,
  :device_gone}` (AC-N4-5: no provider request).
- Relay unreachable for hours → retries capped at 5 min; N5 staleness folds on recovery
  (AC-N4-7).

## Compatibility and rollout

Inert unless `push.enabled: true` and at least one device registered. Rollback: disable.

## Verification

`src/test/aiur/push/sender_test.exs` (PROPOSED), temp XDG store fixtures:

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"one job per device, each sealed to its own kid"` | two devices → two requests, different `kid`/`sealed` | reuse one seal |
| `"envelope has exactly the contract §8 fields"` | key set equality | add `summary` |
| `"410 marks device gone and stops further sends"` | second job → no request | ignore 410 |
| `"429 schedules retry_after_s"` | outbox next_attempt_at | fixed backoff |
| `"revoked device gets no provider request"` (AC-N4-5) | remove row from `devices.json` fixture between accept and send → 0 requests | send from cached registration |
| `"non-https relay_url is refused unless loopback allowed"` | row skipped | accept any scheme |
| `"urgency high maps to alert_high"` | push_class | constant |

Commands (from `src/`): `mise exec -- mix test test/aiur/push/sender_test.exs`.

## Completion and handoff

- [ ] AC-N4-5 integration test green; request-body field set asserted.
- Dependents: C3-T04, C3-T06, MP-N5-C2 (end-to-end), MP-N4-C7.
