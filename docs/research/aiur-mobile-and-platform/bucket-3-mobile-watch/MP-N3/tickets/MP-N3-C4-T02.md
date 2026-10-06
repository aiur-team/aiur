---
ticket_id: MP-N3-C4-T02
feature_id: MP-N3
chunk_id: MP-N3-C4
bucket: 3-mobile-watch
title: "Instance row rendering per DESIGN-N3: identity, agents, Executor, Commands count, build orders, background agents, freshness"
status: blocked
blocked_by: [DESIGN-N3, MP-N3-C4-T01, MP-N3-C3-T01, MP-N3-C2-T01, MP-N1-C3-T01]
prior_units: []
prior_boundaries: []
prior_features: [MP-N1, MP-E2]
prior_findings: []
size_owner: n/a (new package code)
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-N3-C4-T02 — Instance row

## Identity and outcome

- **Bucket / feature / chunk:** 3 / MP-N3 / MP-N3-C4.
- **User value:** at a glance, per instance: which repository, how many agents, what the Executor
  is doing, how many Commands await the human ("≥ N" when partial), build-order progress where it
  exists, and how fresh all of that is.
- **Deliverable:** `InstanceRow` rendering a `MetaRow` exactly per the approved DESIGN-N3 row
  (field order, density, small-screen drop order Q2, wording Q6), with accessibility labels
  ("Commands awaiting you", from `overview.ex:168-169`).
- **Non-goals:** tapping (T03), data fetching (T01/T04).

## Dependencies and blockers

DESIGN-N3 (all of Q1–Q6 must be answered; this ticket implements them and invents nothing);
MP-N3-C4-T01; MP-N3-C3-T01; MP-N3-C2-T01 (real payloads); MP-N1-C3-T01 (affordance resolver, for
capability-driven hiding of fields).

## Verified starting point (base `45a290e3`)

Dashboard terms: "N units awaiting commands", aria "N Commands awaiting you, M blocking"
(`src/lib/aiur_web/components/operator_control_center/overview.ex:53,168-169`); fleet strip
labels Active, Blocked, Paused, Stuck, Finished, Total (`:8-15`).

## Chosen design

- Each `fieldDisplay.kind` maps to one presentational component: `value`, `at_least` ("≥ N"),
  `unavailable` ("—" with the reason in the accessibility label and a long-press explanation),
  `unknown` ("?" with a legend), `hidden` (not rendered), `paused`, `starting`.
- Freshness pill: always rendered on `stale`, `machine_unreachable` and `gateway_offline` rows with
  the age (AGENTS.md: a computed age is rendered); on `live` rows the age appears only in the
  machine header "updated <age> ago" (DESIGN-N3 surface 4).
- Two clones of one repo: show `project_root_basename` as the disambiguator.
- Executor background agents: rendered only when `background_agents` is `available`.

## Implementation steps

1. `InstanceRow.tsx` and field components; accessibility labels.
2. Snapshot tests per fixture scenario. About 200 lines.

## Non-happy paths

Every non-`value` field kind; long repository names (truncate middle, full name in the label);
320 px width (DESIGN-N3 drop order).

## Compatibility and rollout

App-internal.

## Verification

`packages/aiur-mobile/src/screens/meta/__tests__/InstanceRow.test.tsx` — one render test per
C3-T02 scenario, asserting the accessibility tree (not pixels):

1. `"unavailable count renders as unavailable, never 0"`. Mutation: render `value ?? 0` → fails.
2. `"partial count renders at least N"`.
3. `"paused fleet renders paused"`.
4. `"stale row renders its age"`. Mutation: drop the pill → fails.
5. `"disabled build orders field is absent"`; 6. `"nil progress renders unavailable"`.
7. `"two clones show basenames"`.

```bash
npm --prefix packages/aiur-mobile test -- src/screens/meta/__tests__/InstanceRow.test.tsx
```

Device: DV-P6-style width check at 320–430 px on the iPhone and Android slots (MP-N1 device-validation.md).

## Completion and handoff

- [ ] Tests pass; DESIGN-N3 reviewer signs off a fixture walkthrough (fixture gateway, all scenarios).
- [ ] Docs: mobile guide "Reading an instance row" (states and what "—", "?", "≥" mean).
- [ ] Dependents: MP-N7 compact list mirrors the same keys.
