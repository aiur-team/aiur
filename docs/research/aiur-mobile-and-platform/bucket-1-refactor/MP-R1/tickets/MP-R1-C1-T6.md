---
ticket_id: MP-R1-C1-T6
feature_id: MP-R1
chunk_id: MP-R1-C1
bucket: 1-refactor
title: Absorb MP-E1's build-queue source-scan test into manifest seam rules (RC-11, X-1)
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T3, MP-E1-C1-T6]
prior_units: []
prior_boundaries: ["ORC #12", "DSP #13", "BO #30"]
prior_features: [MP-E1]
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C1-T6 — Build-queue seam rules replace MP-E1's scan test

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C1. RC-11: MP-E1 ships in wave 0 with
  its own source-scan test; "R1-C1 absorbs it later". This is that ticket.
- **User value:** none at runtime. One mechanism (the component checker) instead of two
  for the same seam, and the two narrow edges MP-E1 needs (X-1) become explicit,
  reviewable manifest data instead of exceptions buried in a test.
- **Deliverable:**
  1. Manifest entry `build-queue` with `paths: ["src/lib/aiur/build_queue/**"]`,
     `facades: ["Aiur.BuildQueue", "Aiur.BuildQueue.Hints", "Aiur.BuildQueue.ClaimProbe"]`,
     `requires: [tracker, event-bus, config, identity]`, `optional: [build-orders]`.
  2. A `seams` list in `components.json` (schema extended) for edges that cross the
     R-optional rule on purpose:
     - `orchestration → Aiur.BuildQueue.Hints` (rank and hold read in `DispatchPolicy`);
     - `orchestration` implements behaviour `Aiur.BuildQueue.ClaimProbe` (a reference to a
       behaviour module from `@behaviour` counts as a reference and is permitted only by
       this seam);
     - `build-queue → Aiur.BuildOrder.*` only from the single source module MP-E1 names
       (`src/lib/aiur/build_queue/sources/build_order.ex`).
  3. Two extra rules restricted to `build-queue`: no reference to `Aiur.Orchestrator*`
     and no reference to `Aiur.GitHub.*` (component-map §4), checked without an
     allowlist (they must be zero).
  4. Delete MP-E1's ExUnit source-scan test in the same PR.
- **Non-goals:** changing any build-queue code.

## Dependencies and blockers

- DESIGN-R1 §1; C1-T3 (R-optional exists); **MP-E1-C1-T6** (the scan test exists on
  `main`; its exact file path is taken from that merged PR — MP-E1 chunks name it
  "Source-scan test: no `Aiur.Orchestrator` or `Aiur.GitHub` reference under
  `build_queue/`; `Aiur.BuildOrder` only in `sources/build_order.ex`",
  `bucket-2-platform/MP-E1/chunks.md:54`).
- If MP-E1 changed module names (`Hints`, `ClaimProbe`, source path) before merging, use
  the merged names and update component-map §4.

## Verified starting point (`45a290e3`)

- `src/lib/aiur/build_queue/` does not exist at `45a290e3`; MP-E1 creates it.
- MP-E1 design: `Hints` is an ETS read in `DispatchPolicy` returning neutral values when
  the table is absent; `ClaimProbe` is implemented in orchestration and registered
  through application config (`bucket-2-platform/MP-E1/plan.md:126-135`, item X-1 in
  `chunks.md:254-257`).
- No orchestrator module references `Aiur.BuildOrder` at base
  (`git grep -l 'Aiur.BuildOrder' 45a290e3 -- src/lib/aiur/orchestrator` is empty).

## Chosen design

- `seams` entries are `{from, to_module, kind: reference|behaviour, only_paths?, reason}`.
  A seam suppresses R-optional/R-declared for exactly that pair; anything else from the
  same source to the same component still fails.
- The two "must be zero" rules are expressed as `forbid` entries on the component
  (`{"forbid": ["Aiur.Orchestrator", "Aiur.Orchestrator.*", "Aiur.GitHub.*"]}`) so other
  components can reuse the mechanism later (for example C9's listener cursor rule).

## Implementation steps

1. Extend schema with `seams` and `forbid`.
2. Implement both in `check-components.py`.
3. Add the build-queue manifest entry and seams; run; expect exit 0.
4. Delete the MP-E1 scan test; mention it in the PR body with its path.

## Non-happy paths

- MP-E1 not merged yet → this ticket waits (blocked_by). The E1 scan test stays the
  guard meanwhile.
- A future build-queue module legitimately needs another orchestration edge → new seam
  line with a reason naming the ticket; reviewed like an allowlist line.

## Compatibility and rollout

No runtime change. Rollback: revert (restores the E1 test).

## Verification

| Test | Fixture | Expected |
|---|---|---|
| `forbidden_orchestrator_ref_fails` | build-queue file references `Aiur.Orchestrator` | exit 1 `forbid` |
| `forbidden_github_ref_fails` | references `Aiur.GitHub.Labels` | exit 1 |
| `build_order_only_in_source_module` | `Aiur.BuildOrder.X` referenced from `build_queue/server.ex` | exit 1; from `build_queue/sources/build_order.ex` exit 0 |
| `hints_seam_passes` | orchestration references `Aiur.BuildQueue.Hints` | exit 0 |
| `other_build_queue_module_from_orchestration_fails` | orchestration references `Aiur.BuildQueue.Server` | exit 1 |
| `claim_probe_behaviour_seam` | `@behaviour Aiur.BuildQueue.ClaimProbe` in orchestration | exit 0 |

Equivalence: before deleting the E1 test, run it and the new rules against a scratch
commit that adds `alias Aiur.Orchestrator` to a build-queue file; both must fail.

Mutation check: remove `only_paths` handling → `build_order_only_in_source_module` fails.

## Completion and handoff

- [ ] E1 scan test deleted; manifest seams and forbids in place; lint green.
- [ ] component-map §4 table updated with the merged names (if they changed).
- [ ] No docs-site change.
- **Dependents:** C8 (build-queue final shape, path-map row PR-11).
