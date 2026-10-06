---
ticket_id: MP-N3-C3-T02
feature_id: MP-N3
chunk_id: MP-N3-C3
bucket: 3-mobile-watch
title: "Shared meta-dashboard fixtures (registry + summary JSON with expected rows), used by gateway, phone and watch tests"
status: blocked
blocked_by: [DESIGN-N3, MP-N1-C1-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-N1, MP-N2, MP-N7]
prior_findings: []
size_owner: n/a (fixtures)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N3-C3-T02 — Shared fixtures

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N3 / MP-N3-C3.
- **User value:** one set of bytes defines what each instance state looks like, so the gateway
  (Elixir), the phone (TypeScript) and the watches (Swift, Kotlin) cannot drift.
- **Deliverable:** `packages/aiur-mobile/fixtures/meta-row/` (PROPOSED) with one directory per
  scenario: `input.json` (a `GET /v1/instances?include=summary` response plus client reachability)
  and `expected.json` (MetaRow output keys). Plus a JSON Schema check run in CI.
- **Non-goals:** UI snapshots.

## Dependencies and blockers

DESIGN-N3 (may add scenarios), MP-N1-C1-T01 (package). Concurrent with everything in C1/C2.

## Verified starting point (base `45a290e3`)

Contract §6.3/§7 define the shapes. Fixture precedent: `src/test/browser/fixture_server.exs`
(synthetic dashboard data) and the memory note on the OCC parity fixture.

## Chosen design — scenarios (minimum)

`live_basic`, `live_paused`, `stale_heartbeat`, `crashed_record`, `stopped_recent`, `starting`,
`summary_unsupported`, `summary_timeout`, `commands_partial`, `commands_unavailable`,
`build_orders_disabled`, `build_orders_two_roots`, `build_orders_progress_nil`,
`executor_stalled_and_active`, `executor_absent`, `no_dashboard_reachable_for_devices_false`,
`machine_unreachable_cached`, `gateway_offline`, `device_revoked`, `two_clones_same_repo`,
`zero_instances`, `thirty_agents_ten_commands` (size budget). Each `expected.json` lists row keys
only (no copy).

The gateway's Elixir tests (MP-N3-C2-T01) read the same `input.json` files to assert they are
valid gateway output (`include=summary` encoder round-trip).

## Implementation steps

1. Write the fixture files and `fixtures/meta-row/schema.json`.
2. A CI step (in `mobile-package.yml`, MP-N1-C1-T02) validates each `input.json` against the schema.

## Non-happy paths

n/a — fixtures; each non-happy state is itself a scenario.

## Compatibility and rollout

When contract §7 changes, the schema and fixtures change in the same PR.

## Verification

- `packages/aiur-mobile/fixtures/meta-row/__tests__/schema.test.ts`: every `input.json` validates;
  `thirty_agents_ten_commands` summaries encode ≤ 4 096 bytes each.
- `src/test/aiur/machine/registry_fixture_test.exs`: the gateway encoder reproduces each `input.json`
  from its source structs (mutation: drop `lower_bound` from the encoder → `commands_partial` fails).

```bash
npm --prefix packages/aiur-mobile test -- fixtures/meta-row
env HOME="$(mktemp -d)" XDG_CONFIG_HOME="$(mktemp -d)" -u GITHUB_TOKEN -u GH_TOKEN \
  mise exec -- mix test test/aiur/machine/registry_fixture_test.exs
```

## Completion and handoff

- [ ] Fixtures and schema merged; both test commands pass.
- [ ] Dependents: MP-N3-C3-T01, MP-N3-C5-T01, MP-N7 Swift/Kotlin list tests.
