---
ticket_id: MP-N6-C1-T04
feature_id: MP-N6
chunk_id: MP-N6-C1
bucket: 3-mobile-watch
title: Capability gating for device Command routes (commands.read / commands.answer) and typed errors
status: ready
blocked_by: [DESIGN-N6 (no-UI release), MP-N6-C1-T03, MP-R1 capability registry (R1-C2/C3, RC-12)]
prior_units: []
prior_boundaries: [WEB #34]
prior_features: [MP-R1]
prior_findings: [identity-and-capabilities §3 rule 6 (writes re-checked server-side, typed error naming the capability)]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C1-T04 — Capability gating

## Identity and outcome

Bucket 3, MP-N6, chunk C1. Make the device Command routes consistent with the capability
report: register `commands.read` and `commands.answer` (if MP-R1 has not), and make every
refusal a typed error that names the capability:
`{"error":"capability_unavailable","capability":"commands.answer","reason":"disabled"}`
(`dashboard_writable: false`), `…"reason":"dependency_unavailable","depends_on":["orchestration"]`
(answers recorded but not delivered: `degraded`, still accepted with
`delivery.status: "pending"`).

## Dependencies and blockers

C1-T03, MP-R1 capability registry. DESIGN-N6 no-UI release.

## Verified starting point

- Identity-and-capabilities §2.2 reasons; §4 row "Daemon up, orchestrator crashed →
  `commands.answer: degraded/dependency_unavailable` (answers recorded, not delivered)".
- Client capability model §5: "Answer a Command … Writes when stale: Yes, with
  `expected_version`".
- `require_dashboard_writable/2` returns `403 {"error":"dashboard is read-only"}`
  (`router.ex:230-241`): this ticket wraps device routes with a device-specific plug that
  returns the typed body instead, without changing the dashboard's behaviour.

## Chosen design

A small plug `AiurWeb.DeviceCapabilityGate` (PROPOSED) placed after `:device_auth`; reads
the registry (no orchestrator call) and refuses with the typed body; `:require_writable`
stays as defence in depth.

## Implementation steps

Plug + registration callbacks + tests.

## Non-happy paths

Registry unknown state → refuse writes with `reason: "unknown"` (never assume available).

## Compatibility and rollout

Device routes only.

## Verification

| Test | Expected | Must fail without |
| --- | --- | --- |
| `"read-only dashboard → typed capability error"` | 403 typed body | generic body |
| `"orchestrator down → answer accepted with pending delivery"` | 200 `accepted`, `delivery.status: pending` | refuse |
| `"unknown capability state refuses writes with unknown"` | `reason: unknown` | allow (unknown-path rule) |

Commands (from `src/`): `mise exec -- mix test test/aiur_web/controllers/device_command_controller_test.exs`.

## Completion and handoff

- [ ] Dependents: C3-T02 (renders typed errors), C4-T01 (mic gating uses the same rule).
