---
ticket_id: MP-N6-C2-T01
feature_id: MP-N6
chunk_id: MP-N6-C2
bucket: 3-mobile-watch
title: Pure destination resolver — machine → instance → target → anchor with visible degradation
status: ready
blocked_by: [DESIGN-N6, MP-N4-C4-T02, MP-N4-C5-T02, MP-N2-C5-T5, N1-C3-T1]
prior_units: []
prior_boundaries: [mobile-app]
prior_features: [MP-N4, MP-N2, MP-N1]
prior_findings: [notification contract v2 §3.1 rules 1–4]
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N6-C2-T01 — Destination resolver

## Identity and outcome

Bucket 3, MP-N6, chunk C2. A pure TypeScript module in `packages/aiur-mobile` (PROPOSED
`src/notifications/resolveDestination.ts`, with a Swift/Kotlin twin only if MP-N7's watch
needs it natively) implementing notification contract v2 §3.1:

```ts
resolve(dest: Destination, registry: PairedRegistry, probe: InstanceProbe): Promise<Screen>
type Screen =
  | {kind: "not_paired", machine_id}
  | {kind: "unreachable", machine_id, sealedSummary}
  | {kind: "instance_changed", instance_id}
  | {kind: "instance", instance_id, note: "command_gone" | "target_unsupported" | null}
  | {kind: "command", instance_id, decision_id, anchor: Anchor | null}
  | {kind: "build_order", instance_id, root_id}
  | {kind: "conversation", instance_id, agent}
```

Rules: machine by `machine_id` only (never display name); `instance_id` must start with
`machine_id + "/"`; the reached instance must report the same `instance_id` and `repo`
(capability report, MP-R1) else `instance_changed`; Command `404` → `instance` with
`command_gone`; never a generic inbox.

## Dependencies and blockers

- MP-N4-C4-T02 / C5-T02 (accepted payload → destination), MP-N2-C5-T5 (paired registry),
  N1-C3-T1 (capability cache / probe).
- DESIGN-N6 gate: the resolver returns screen kinds; the screens and notes' copy are
  C2-T02/C3. Content of DESIGN-N6 does not change the rules (contract-fixed), so ready.

## Verified starting point

No mobile code at `45a290e3`. Contract v2 §3.1 (destination fields incl. `instance_id`,
rules 1–4); MP-N6-C1-T01 (`404` vs `withdrawn`).

## Chosen design

The probe call is `GET /api/v1/device/commands/:id` for Command targets (one round trip
gives instance identity via `instance_id` in the body) and `GET /api/v1/capabilities`
otherwise.

## Implementation steps

Module + fixtures for every missing level; no UI.

## Non-happy paths

Every level's absence is a test fixture (the module's whole purpose).

## Compatibility and rollout

Unknown `target.kind` → `instance` with `target_unsupported` (forward compatibility).

## Verification

Jest/Vitest (per MP-N1-C1) `resolveDestination.test.ts` (PROPOSED):

| Test | Expected | Must fail without |
| --- | --- | --- |
| `not paired machine → not_paired, no network call` | probe not called | probe first |
| `instance_id prefix mismatch → malformed rejected` | throws `MalformedDestination` | skip check |
| `repo mismatch → instance_changed` | as stated | trust instance_key |
| `command 404 → instance with command_gone` | as stated | fall back to an inbox screen (unknown-path rule) |
| `unreachable → unreachable with sealed summary` | as stated | `not_paired` |

Command: `npm --prefix packages/aiur-mobile test` (per MP-N1-C1).

## Completion and handoff

- [ ] Dependents: C2-T02, C2-T03, C5-T01.
