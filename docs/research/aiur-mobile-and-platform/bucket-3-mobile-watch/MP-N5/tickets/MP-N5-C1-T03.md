---
ticket_id: MP-N5-C1-T03
feature_id: MP-N5
chunk_id: MP-N5-C1
bucket: 3-mobile-watch
title: Settings API — gateway GET/PATCH /v1/notification-settings and instance notification-options
status: ready
blocked_by: [DESIGN-N5 (no-UI release), MP-N5-C1-T02, MP-N2-C4-T04, MP-N2-C6-T01, RQ-TRANSPORT (RC-15)]
prior_units: []
prior_boundaries: [WEB #34 (router), pairing gateway (MP-N2)]
prior_features: [MP-N2]
prior_findings: [pairing contract §4.4 (device token on instance routes), A-N2-4]
size_owner: router.ex — web-shell owner per U8 ledger
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N5-C1-T03 — Settings API

## Identity and outcome

Bucket 3, MP-N5, chunk C1. Two endpoints, both device-token authenticated:

1. **Gateway** (MP-N2 process, single writer of the machine store):
   - `GET /v1/notification-settings` → the calling device's record (C1-T01) +
     `version`, signed like other gateway responses (`contract: "aiur.machine/v1"`).
   - `PATCH /v1/notification-settings` `{expected_version, patch}` → `200 {record}` |
     `409 {error: "version_conflict", current}` | `422 {error, key}`.
   A device can read and write **only its own** record (`device_id` from the token, never
   from the body).
2. **Instance** (per daemon): `GET /api/v1/device/notification-options` → for that
   instance, each option's effective value and availability (C1-T02) with
   `observed_at`, `age_ms`, `freshness`.

## Dependencies and blockers

- C1-T02; MP-N2-C4-T04 (gateway routes + token plug), MP-N2-C6-T01 (instance device-auth
  pipeline). RQ-TRANSPORT (RC-15): the phone reaches these over the transport DESIGN-N2
  chooses; the API itself does not change with the choice, but end-to-end use waits.
- DESIGN-N5 no-UI release.

## Verified starting point

- Instance routing at `45a290e3`: `/api/v1/state` etc. under `:dashboard_auth`
  (`src/lib/aiur_web/router.ex:186-199`) ending in `get("/api/v1/:issue_identifier", …)`
  and `match(:*, "/*path", …)` catch-alls — new device routes must be declared **before**
  that scope (same rule the capability contract §2.1 states for `/api/v1/capabilities`).
- Pairing contract §4.4: instances accept the device bearer; device auth does not widen
  authority. This route is read-only.
- AGENTS.md "If a surface computes an age, it renders the age" → `age_ms`/`freshness`.

## Chosen design

- Instance scope (PROPOSED):
  `scope "/", AiurWeb do pipe_through(:device_auth); get("/api/v1/device/notification-options", DeviceNotificationOptionsController, :show) end`
  placed above the `:dashboard_auth` API scope. `:device_auth` is the MP-N2-C6 pipeline
  name (CR-N5-1 confirms the name).
- Response: `{"contract":"aiur.notification-options/1","instance_id":…,"observed_at":…,
  "age_ms":…,"freshness":…,"options":{"progress_step_pct":{"value":25,"state":"unavailable",
  "reason":"build_orders_not_installed"}, …}}`.
- Gateway handler lives in the MP-N2 gateway router (PROPOSED module
  `AiurMachineGateway.NotificationSettingsController`); it uses `Preferences.File.write/3`.

## Implementation steps

1. Instance controller + route + tests.
2. Gateway controller + route + tests (in the gateway test suite).
3. `website/docs-app/reference/` API page? — no public API page exists for device routes;
   document both in the MP-N2 pairing guide section on device APIs (C5-T01).

## Non-happy paths

- Revoked/expired token → `401 device_revoked` with no body content (pairing contract
  §4.2).
- Mobile disabled → `401 device_auth_disabled`.
- Gateway down → phone cannot save; instance options still readable (instances read the
  store directly) — DESIGN-N5 "machine unreachable" state.
- Concurrent PATCH from two app instances of one device → second gets `409`.

## Compatibility and rollout

New routes only; Basic-Auth routes unchanged.

## Verification

`src/test/aiur_web/controllers/device_notification_options_controller_test.exs` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"route is not swallowed by the issue catch-all"` | 200 with options JSON | declare route after `/api/v1/:issue_identifier` |
| `"no device token → 401 with empty body"` | 401 | reuse `:dashboard_auth` only |
| `"unavailable option carries reason, not value-only"` | `state`, `reason` present | drop availability |
| `"age_ms and freshness rendered"` | both present | omit |

Gateway tests: `"device can only patch its own record"` (body `device_id` ignored; must
fail if read from body), `"stale expected_version → 409 with current"`.

Commands (from `src/`): `mise exec -- mix test test/aiur_web/controllers/device_notification_options_controller_test.exs`
and the gateway suite path from MP-N2-C4.

## Completion and handoff

- [ ] Routes ordered before catch-alls (test proves it).
- Dependents: C4-T01..T03 (phone screens), MP-N3 (instance view may show muted/badges).
