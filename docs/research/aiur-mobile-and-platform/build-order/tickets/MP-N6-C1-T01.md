---
ticket_id: MP-N6-C1-T01
feature_id: MP-N6
chunk_id: MP-N6-C1
bucket: 3-mobile-watch
title: Device Command API — scope, pipelines and GET /api/v1/device/commands/:id view model
status: ready
blocked_by: [DESIGN-N6 (no-UI release), MP-N6-C1-T00, MP-N2-C6-T01, MP-N2-C6-T03, MP-E2-C1-T01, MP-E2-C1-T04, MP-E4-C3-T02, RQ-TRANSPORT (RC-15)]
prior_units: []
prior_boundaries: [DEC #27, WEB #34]
prior_features: [MP-E2, MP-E4, MP-N2]
prior_findings: [supervisor API is Executor-credentialed (router.ex:79-95), A-N2-4]
size_owner: router.ex — web-shell owner per U8 ledger
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C1-T01 — Device Command read API

## Identity and outcome

Bucket 3, MP-N6, chunk C1. Add the device-authenticated router scope for all MP-N6 device
routes and the read endpoint
`GET /api/v1/device/commands/:decision_id` returning the Command view the phone and watch
render: E2 presentation fields (DESIGN-E2 §4.1–4.2 anatomy — question, short label,
context, options with recommended marker, consequence of delay, urgency, blocking,
authority), status, `version`, routing state (E2), requester (worker ticket or Executor),
delivery state, `anchor` (`{conversation_id, pos, anchor_id, precision}` from MP-E4-C3, or
`null`), and `instance_id` so the app can check it reached the right instance
(notification contract §3.1 rule 3).

## Dependencies and blockers

- MP-N2-C6-T01 (device-auth plug), MP-E2-C1-T01/T04 (v2 fields and read API shape),
  MP-E4-C3 (anchor lookup by `decision_id`), C1-T00.
- RQ-TRANSPORT (RC-15): the phone reaches the instance over the transport DESIGN-N2 picks;
  the API is identical either way.
- DESIGN-N6 header: "The device Command API (MP-N6-C1) may proceed."

## Verified starting point

- Supervisor read routes `GET /api/v1/decisions[/:decision_id]` are behind
  `:supervisor_auth` (`router.ex:94-99`); the actor identity there is the supervisor
  (`AiurWeb.SupervisorAuth`), so phones must not reuse them (N6 plan §7).
- Dashboard API scope ends with `get("/api/v1/:issue_identifier", …)` and
  `match(:*, "/*path", …)` (`router.ex:186-199`): device routes must be declared earlier.
- `Aiur.DecisionStore.get/2 :: {:ok, Decision.t()} | {:error, :not_found}`
  (`decision_store.ex:388`); retired statuses `:expired | :moot | :resolved`
  (`decision_store.ex:1440-1441`).
- `Aiur.Decision` fields (`decision.ex:18-42,120-136`).

## Chosen design

```elixir
# PROPOSED, above the :dashboard_auth API scope.
# :device_auth (MP-N2-C6-T01) and :device_write (MP-N2-C6-T03) are defined by MP-N2
# (pairing contract §4.4, Phase D); this ticket only uses them.

scope "/api/v1/device", AiurWeb do
  pipe_through(:device_auth)        # MP-N2-C6 name (CR-N6-1)
  get("/commands", DeviceCommandController, :index)          # C1-T02
  get("/commands/:decision_id", DeviceCommandController, :show)
end

scope "/api/v1/device", AiurWeb do
  pipe_through([:device_auth, :device_write, :require_writable])
  post("/commands/:decision_id/answer", DeviceCommandController, :answer)   # C1-T03
end
```

- `:api_write`'s origin check is **not** used: native clients send no `Origin`
  (`verify_same_origin/2`, `router.ex:215-224`, would 403 them); a bearer token is not
  ambient, so CSRF does not apply; the custom header keeps the same "deliberate request"
  signal. Answers are writable-gated because dashboard answers are
  (`dashboard_live.ex:587-592` → `handle_writable_event`); device auth never widens
  authority (pairing contract §4.4).
- `show` JSON: `{"contract":"aiur.device-command/1","instance_id","decision_id","version",
  "status","withdrawn": null | {"reason": "expired|moot|resolved"}, "presentation": {…},
  "routing": {…}, "requester": {…}, "delivery": {…}, "anchor": {…}|null,
  "answer": null | {"actor_kind","accepted_at","summary"}, "observed_at"}`.
- `404 command_not_found` only when the store has no such id; a retired Command is
  `200` with `withdrawn` set (the app shows "No longer needed", N6 plan §5.2).
- No `long_context_markdown` truncation server-side; the app lays it out (DESIGN-N6).

## Implementation steps

1. `src/lib/aiur_web/controllers/device_command_controller.ex` (PROPOSED) `show/2`;
   `src/lib/aiur_web/device_command_view.ex` (PROPOSED) pure view builder.
2. Router scope above the dashboard API scope; reuse `require_custom_header/2`.
3. Tests.

## Non-happy paths

- No/expired/revoked token → `401` (`device_revoked` | `device_auth_disabled`) with no
  Command data (AC-N6-6).
- Store unavailable → `503 decision_service_unavailable` (same code as
  `decision_api_controller.ex:157-159`).
- Anchor resolver unavailable → `anchor: null` with `anchor_state: "unavailable"`; never
  blocks the Command view.

## Compatibility and rollout

New routes; existing routes unchanged. Rollback: remove the scope.

## Verification

`src/test/aiur_web/controllers/device_command_controller_test.exs` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"device route is not swallowed by /api/v1/:issue_identifier"` | 200 JSON from DeviceCommandController | declare the scope after the dashboard scope |
| `"revoked device gets 401 and no Command fields"` (AC-N6-6) | body lacks `presentation` | render before auth |
| `"retired Command is 200 withdrawn, unknown id is 404"` | both | map retired to 404 |
| `"view carries version and instance_id"` | present | omit |
| `"anchor unavailable does not fail the view"` | `anchor: null`, 200 | propagate error |
| `"Basic-Auth credentials alone do not open device routes"` | 401 | pipe through `:dashboard_auth` |

Commands (from `src/`): `mise exec -- mix test test/aiur_web/controllers/device_command_controller_test.exs`,
`mise exec -- mix test test/aiur_web/router_auth_test.exs` (existing router auth suite at
`45a290e3`; add the device-scope ordering case there).

## Completion and handoff

- [ ] Route-order and auth tests green.
- Docs: device API section in the MP-N2 pairing guide (MP-N2-C9) gains these routes.
- Dependents: C1-T02, C1-T03, C2-*, C3-*, C5-*.
