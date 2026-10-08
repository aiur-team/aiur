---
ticket_id: MP-N4-C3-T05
feature_id: MP-N4
chunk_id: MP-N4-C3
bucket: 3-mobile-watch
title: Push deregistration hook for revoke and unpair-all; per-instance purge
status: ready
blocked_by: [DESIGN-N4 (no-UI release), MP-N4-C3-T03, MP-N2-C7-T03]
prior_units: []
prior_boundaries: [new #41 candidate push-relay]
prior_features: [MP-N2]
prior_findings: [pairing contract §4.5 (control vs push revocation), D19, AC-N4-5]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N4-C3-T05 — Deregistration

## Identity and outcome

Bucket 3, MP-N4, chunk C3. Two pieces:

1. `Aiur.Push.Deregister.deregister(push_registration) :: :ok | {:retry, reason}`
   (PROPOSED), implementing MP-N2's behaviour `Aiur.Machine.PushDeregistrar`
   (MP-N2-C7-T03; one interface, Phase D coordinator item N2-4), a **pure library function** the MP-N2 gateway calls on revoke and
   unpair-all (pairing contract §4.5; MP-N2-C7-T03 owns the persisted retry outbox). It
   sends `DELETE <relay_url>/v1/handles/<handle>` with `Authorization: Bearer
   <send_secret>`; `204`/`404` → `:ok`; anything else → `{:retry, reason}` (Phase D X-12: one return shape with the behaviour above and MP-N2-C7-T03:48; the gateway, not this function, renders that as "pending").
2. Per-instance purge: when a device disappears from `devices.json` (mtime change), each
   instance's push component calls `Outbox.purge_device/1` and forgets its device state.

User value: D19 "unpair stops all pushes to it within one send" (N4-R7, AC-N4-5); the
gateway reports push deregistration separately as "pending" when the relay is down.

## Dependencies and blockers

- C3-T03 (registry cache to diff), MP-N2-C7-T03 (gateway deregistration outbox calling
  this function; until it exists, MP-N2 stubs the hook). DESIGN-N4: no UI.

## Verified starting point

- Pairing contract §4.5: revoke "Calls the MP-N4 deregistration hook (best effort,
  retried)"; unpair-all "call MP-N4 for each device"; result reports control revocation
  (synchronous) separately from push deregistration ("may be pending").
- Contract v2 §7: `DELETE /v1/handles/:handle` with `send_secret` revokes.

## Chosen design

- The function holds no state and never reads the machine store; the gateway passes the
  row's `push_registration` it is deleting (it must capture it before deleting the row).
- Timeout 5 s. No retries inside (the gateway's outbox retries).
- Purge: the registry cache (C3-T03) compares device id sets on reload; removed ids →
  purge. A device that is only `gone` (relay `410`) is not purged (it may re-register).

## Implementation steps

1. `src/lib/aiur/push/deregister.ex` (PROPOSED).
2. Registry diff → `Outbox.purge_device/1`.
3. Tests with the fake relay.

## Non-happy paths

- Relay down during revoke → `{:retry, :relay_unreachable}` (N2 reports it as `pending`); control revocation already
  happened, so the daemon sends nothing (registry miss) even while the handle exists.
  The only residual risk is that the relay keeps a dead handle until retry succeeds.
- `push_registration` malformed → `:ok` with a warning (nothing to delete remotely).

## Compatibility and rollout

Library function; no config. Gateway integration in MP-N2-C7-T03.

## Verification

`src/test/aiur/push/deregister_test.exs` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"204 and 404 are ok"` | `:ok` | treat 404 as pending |
| `"5xx and timeout are retry"` | `{:retry, _}` | swallow as ok |
| `"sends bearer send_secret"` | header present | omit header |
| `"device removed from devices.json purges its outbox jobs"` | pending jobs terminal `{:dropped, :device_gone}` and no provider request (AC-N4-5) | skip the diff |
| `"unpair-all removes every device → zero sends"` (V-S3 analogue) | 0 requests for queued jobs | — |

Commands (from `src/`): `mise exec -- mix test test/aiur/push/deregister_test.exs`.

## Completion and handoff

- [ ] MP-N2-C7-T03 calls the function (cross-checked in its PR).
- Dependents: MP-N2-C7, MP-N4-C7 (V-S2, V-S3).
