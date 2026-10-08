---
ticket_id: MP-N3-C3-T01
feature_id: MP-N3
chunk_id: MP-N3-C3
bucket: 3-mobile-watch
title: "MetaRow view model (TypeScript): row-state priority and per-field display rules"
status: blocked
blocked_by: [DESIGN-N3, MP-N1-C1-T01, MP-N3-C3-T02]
prior_units: []
prior_boundaries: []
prior_features: [MP-N1, MP-N2]
prior_findings: []
size_owner: n/a (new package code)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N3-C3-T01 — MetaRow view model

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N3 / MP-N3-C3 "MetaRow view model".
- **User value:** every surface that lists instances (phone list, watch list via the phone
  snapshot) states the same truth: unreachable, stale, unavailable, paused and zero are never
  confused.
- **Deliverable:** a pure function `toMetaRows(machines: MachineState[], now): MachineSection[]`
  in `packages/aiur-mobile/src/meta/metaRow.ts` (PROPOSED), driven by the shared fixtures of
  MP-N3-C3-T02. No UI.
- **Non-goals:** layout and copy (DESIGN-N3; the model emits **keys**, not strings), grouping vs
  sorting (DESIGN-N3 Q1 — the model emits both a machine-grouped list and a stable urgency key so the
  screen can do either without changing the model).

## Dependencies and blockers

- DESIGN-N3 (field set and Q1–Q6 may adjust keys; the state priority below is contract-driven).
- MP-N1-C1-T01 (package skeleton and test runner); MP-N3-C3-T02 (fixtures).
- Concurrent with MP-N3-C1, C2 (works from the contract).
- Dependents: MP-N3-C4-T02, MP-N1-C3-T04 (watch snapshot projection reuses the row model), MP-N7.

## Verified starting point (base `45a290e3`)

No mobile code exists. Inputs are the contract shapes: `InstanceEntry` (§6.3), summary Facts
(§7), machine reachability from the client (client-capability-model.md I2/I3). Dashboard
wording to mirror by key: "Command counts unavailable", "Partial Command counts"
(`src/lib/aiur_web/components/operator_control_center/overview.ex:79-89`).

## Chosen design

**Machine state** (first match): `revoked` (401 `device_revoked`) → `gateway_offline` (endpoint
answers but gateway down, or `device_auth_disabled`) → `unreachable` (no endpoint answered;
carries `transport_error.kind`) → `live`.

**Row state** (first match, MP-N3 plan §5):

| # | Condition | `rowState` |
|---|---|---|
| 1 | machine `unreachable` / `gateway_offline` | `machine_unreachable` / `gateway_offline`, cached values with `lastSeenAgeMs` |
| 2 | machine `revoked` | row removed; machine goes to a `removed` section once |
| 3 | entry `crashed` / `stopped` | `crashed` / `stopped` (dimmed, excluded from totals) |
| 4 | entry `starting` | `starting` |
| 5 | entry `unknown` | `unknown` |
| 6 | summary `unsupported` | `summary_unsupported` (identity only + update hint key) |
| 7 | entry `stale`, or summary age > 2 poll intervals (30 s) | `stale` with `ageMs` |
| 8 | otherwise | `live` |

**Field display** (each field independently): Fact `available` → `{kind: "value", value}`;
`available` + `lower_bound` → `{kind: "at_least", value}`; `unavailable` → `{kind:
"unavailable", reason}`; `disabled` → `{kind: "hidden"}`; `unknown` → `{kind: "unknown"}`.
`agents.active` with `fleet.globally_paused: true` → `{kind: "paused"}`; `agents.active`
`unavailable` with reason `starting` → `{kind: "starting"}`. Executor value passes through
(`active|idle|stalled|expired|absent|unknown`). Build orders: `{kind: "build_orders", count,
primary}` where `primary` is selected by a pluggable rule (default: first root = most recently
updated; DESIGN-N3 Q3 may change the rule, not the model shape).

**Invariant:** the function never produces a numeric value from a non-`available` Fact. The
`urgencyKey` is `[awaiting_blocking desc, executor==stalled, awaiting desc, label]` and is a sort
key only — no Command content is merged (no combined inbox).

## Implementation steps

1. `src/meta/types.ts` from the contract types (generated from `packages/aiur-contracts` once
   MP-R1-C3-T06 publishes the schema; until then hand-written behind one import path).
2. `src/meta/metaRow.ts`, `src/meta/fieldDisplay.ts`. About 200 lines.

## Non-happy paths

All rows above; an `instance_id` seen on two machines (impossible by construction; asserted);
a machine with zero instances → section with `empty: true`, not an error.

## Compatibility and rollout

Pure library. Contract version mismatch: unknown summary major version arrives as
`summary_unsupported` from the gateway.

## Verification

`packages/aiur-mobile/src/meta/__tests__/metaRow.test.ts`, table-driven from
`fixtures/meta-row/*.json` (C3-T02):

1. `"each fixture produces its expected rows"` (one case per fixture file).
2. `"unavailable never renders as a number"` — property test over all Fact statuses. Mutation:
   map `unavailable` to `{kind:"value", value:0}` → fails (AGENTS.md unknown-path guard).
3. `"unknown is not collapsed into unavailable"`. Mutation: map `unknown` → `unavailable` → fails.
4. `"paused fleet shows paused, not 0 active"`.
5. `"crashed rows are excluded from machine totals"`.
6. `"stale threshold is 30 s of summary age"` (boundary 29 999 / 30 001 ms).

```bash
npm --prefix packages/aiur-mobile test -- src/meta
```

## Completion and handoff

- [ ] Tests pass; mutation checks recorded. Docs: none (internal).
- [ ] Dependents: MP-N3-C4-T02; Swift/Kotlin ports in MP-N7 tickets use the same fixtures.
