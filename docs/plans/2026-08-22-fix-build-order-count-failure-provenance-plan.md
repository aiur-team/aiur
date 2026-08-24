---
title: Build Order Count Failure Provenance - Plan
type: fix
date: 2026-08-22
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Build Order Count Failure Provenance - Plan

## Goal Capsule

- Make unresolved epic and wave counts on `/build-orders` explain the bounded failure category that prevented resolution.
- Preserve #2249's explicit distinction between a resolved empty Build Order and an unresolved populated Build Order.
- Stop when budget exhaustion, timeout, upstream failure, generic unresolved, and resolved-zero states have mutation-resistant rendering coverage.

## Product Contract

### Summary

The Build Order catalog will retain the failure provenance from its expensive labelled read and show that category anywhere an epic or wave count is unresolved.

### Requirements

- R1. A failed labelled catalog read retains a safe category after the cheap fallback catalog succeeds.
- R2. Unresolved epic and wave cells visibly distinguish budget exhaustion, timeout, and other upstream failures.
- R3. A resolved zero remains a numeric zero and never inherits failure presentation.
- R4. An unresolved value without classified provenance remains an honest generic unresolved state.
- R5. Tests fail if an unresolved count with failure provenance is rendered as `0` or as the same state as resolved zero.

### Scope Boundaries

- Fix the dashboard catalog path; #2249 already owns the cross-surface empty-state contract.
- Do not change planning budgets, query cadence, retry policy, or GitHub transport behavior.
- Expose only controlled categories, never raw provider payloads.

## Planning Contract

- KTD1. Store count-resolution failure on `Aiur.BuildOrder.Catalog`, because a labelled catalog request resolves the dimensions for the whole catalog and its failure survives independently of any one root.
- KTD2. Retain the latest labelled-read failure in `Aiur.BuildOrder.GraphProjection`; cheap reads may refresh catalog membership but cannot overwrite provenance for dimensions they did not request.
- KTD3. Collapse internal failure atoms at the presentation boundary into `budget exhausted`, `timed out`, and `upstream error`; the existing generic `Unresolved` label remains the fallback when no classified failure is known.
- KTD4. A successful labelled read clears prior request failure provenance; if the labelled response itself publishes unresolved dimensions, classify that as an upstream-data failure rather than silently carrying an earlier count.

## Implementation Units

### U1. Preserve labelled-read failure provenance

- **Goal:** Carry the bounded failure category alongside catalog data through labelled failure, cheap fallback success, and recovery.
- **Files:** `src/lib/aiur/build_order/catalog.ex`, `src/lib/aiur/build_order/graph_projection_options.ex`, `src/lib/aiur/build_order/graph_projection.ex`, `src/test/aiur/build_order/graph_projection_test.exs`.
- **Patterns:** Follow existing `catalog_labels_*` state and the last-known-good count carry policy.
- **Test Scenarios:** Call-budget failure followed by cheap success retains budget provenance; timeout retains timeout provenance; a successful labelled refresh clears the prior failure; a labelled success with unresolved dimensions records upstream-data provenance; resolved counts carry no failure.

### U2. Render actionable unresolved cells

- **Goal:** Show the category visibly without conflating it with zero or generic unresolved.
- **Files:** `src/lib/aiur_web/components/operator_control_center/build_order_catalog.ex`, `src/test/aiur_web/live/build_order_live_test.exs`, `website/docs-app/concepts/build-orders.md`.
- **Patterns:** Extend the existing `data-count-state="unresolved"`, accessible label, and title contract rather than introducing a second badge system.
- **Test Scenarios:** Budget, timeout, and upstream categories each render visible controlled text; resolved zero renders `0`; generic unresolved remains `Unresolved`; all states have distinct HTML and no unresolved failure cell contains numeric zero.

## Verification Contract

- Run `mix compile --warnings-as-errors` and `mix format` from `src/`.
- Run `mix aiur.affected_tests`, then every emitted test command with `mix test --max-cases 4`.
- Exercise the real LiveView component through `build_order_live_test.exs`; agent-workspace policy prohibits `aiurdev --test`, so Executor-root manual TUI verification remains outside this turn.

## Definition of Done

- Every requirement R1-R5 is asserted by collected tests.
- Existing resolved, carried, empty, and generic unresolved behavior remains intact.
- The Build Orders concept page describes actionable unresolved categories.
- The draft PR is self-reviewed, current with `main`, and handed to CI.
