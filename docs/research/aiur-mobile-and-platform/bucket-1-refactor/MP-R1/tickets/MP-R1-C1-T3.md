---
ticket_id: MP-R1-C1-T3
feature_id: MP-R1
chunk_id: MP-R1-C1
bucket: 1-refactor
title: Layer (R-down) and required-to-optional (R-optional) rules with cycle report
status: blocked
blocked_by: [DESIGN-R1, MP-R1-C1-T2]
prior_units: [U0]
prior_boundaries: ["all; six upward-edge classes, feature-boundaries.md §3"]
prior_features: []
prior_findings: []
size_owner: n/a
base_sha: 45a290e3
researched: 2026-10-06
---

# MP-R1-C1-T3 — Layer and optional-dependency rules

## Identity and outcome

- **Bucket / feature / chunk:** Bucket 1, MP-R1, C1. Step S0.
- **User value:** none at runtime. Enforces the two structural rules of
  [component-map.md §2](../component-map.md): a component depends only on its own layer
  or lower (**R-down**), and a required component never depends on an optional one
  (**R-optional**). These are what make optional components removable (brief R1).
- **Deliverable:** two rules in `scripts/check-components.py`, their allowlist entries
  (generated at the head, appended to T2's per-component files), and an informational
  strongly-connected-component report printed on every run.
- **Non-goals:** fixing any violation; declaring new facades.

## Dependencies and blockers

- DESIGN-R1 §1; C1-T2 (walker, allowlist format).
- **Concurrent:** T4, C2, C5. **Dependents:** T5, T6, and the C6–C9 move tickets that
  cite C1-T3 (for example C8-T3, C9-T01).

## Verified starting point (`45a290e3`)

- Upward edges measured with the prior walker and prior layer table
  (`graph_summary.py` `LEVEL`): 339 upward module edges, all 36 prior boundaries in one
  SCC (see C1-T2 for method). The prior relocation simulation removes 77 edges by six
  inversion classes (`orchestrator-callback->event` 17, `backend-registry` 19,
  `config->schema-registration` 24, `remote-session-capability` 10,
  `alert-latch->signal-state` 5, `tracker-adapter-registry` 2) and leaves 133 upward
  edges. Those classes are the work of C4, C5, C7 and MP-R7; this ticket only measures.
- Config upward edges (24) are listed concretely in MP-R1-C4-T1..T4.

## Chosen design

- **R-down:** violation when `layer(target) > layer(source)`. The composition root
  (`control-cli`, L4) needs no exemption: no L5 component contains Elixir code.
- **R-optional:** violation when `source.kind == required` and
  `target.kind == optional` and `target ∈ source.optional` (declared optional edges are
  still forbidden from required code unless they go through a registration point). The
  only allowed form is a reference from the composition root. Example: `orchestration`
  (required) → `build-queue` (optional) through `Aiur.BuildQueue.Hints` is an RC-11 edge;
  it is permitted by C1-T6's explicit `seams` entry, not by a blanket exemption.
- **Allowlist reuse:** same key `(rule, source component, target module)`; each rule
  separately, so removing an R-private violation does not hide an R-down one.
- **Cycle report:** Tarjan SCC over component edges (all references, allowlisted or not);
  printed as `scc: 31 components: [...]`. It never fails the build (KD7: ratchet, not a
  day-one gate) but its size is part of T5's step summary so the trend is visible.

## Implementation steps

1. Add `layer`/`kind` lookups (manifest fields exist from T1).
2. Implement R-down and R-optional over the T2 edge list.
3. Implement SCC (iterative Tarjan, stdlib only).
4. `--write-baseline --rules down,optional` appends to existing allowlist files only for
   these two rules (T2's refusal applies per rule).
5. Fixtures and PR-body counts per rule.

## Non-happy paths

- Manifest with a `requires` cycle is legal (SCC is today's reality); only layer and
  optional rules fail.
- A component with `layer` changed in a later PR changes violations: the checker prints
  which allowlist entries became stale or new; T5 enforces stale removal.

## Compatibility and rollout

No runtime change. Rollback: revert (the rule code and its allowlist lines).

## Verification

| Test | Fixture | Expected |
|---|---|---|
| `upward_reference_fails` | L1 component references an L3 facade it `requires` | exit 1 `R-down` |
| `same_layer_passes` | L2 → L2 declared facade | exit 0 |
| `required_to_optional_fails` | required `a` references optional `b` facade, declared in `a.optional` | exit 1 `R-optional` |
| `composition_root_may_reference_optional` | `src/lib/aiur.ex` references optional facade | exit 0 |
| `optional_to_required_passes` | optional → required facade | exit 0 |
| `scc_reported_not_failed` | `a`↔`b` declared, same layer | exit 0, output contains `scc: 2` |
| `rules_allowlisted_separately` | edge allowlisted for `R-private` only, also upward | exit 1 `R-down` |

Mutation check: swap `>` for `>=` in R-down → `same_layer_passes` fails; remove the
`kind` comparison → `optional_to_required_passes` or `required_to_optional_fails` fails;
key the allowlist without the rule → `rules_allowlisted_separately` fails.

Command: `bash scripts/test-check-components.sh --with-elixir`; real tree
`python3 scripts/check-components.py` exits 0 with the new baseline.

## Completion and handoff

- [ ] Two rules live in the required lint step; baseline counts in the PR body.
- [ ] SCC size printed; recorded in the PR body as the starting value.
- [ ] No docs-site change.
- **Dependents:** C1-T5, C1-T6, every move ticket that claims a removed edge.
