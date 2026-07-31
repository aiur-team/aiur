---
title: "fix: Preserve retained Decision read contracts"
type: fix
status: completed
date: 2026-07-14
---

# fix: Preserve retained Decision read contracts

## Summary

Close the final exact-head DASH-006 review findings without widening the feature: preserve retained health on public detail reads, make v1 offset pages derive from one store snapshot, and centralize the shared Decision sanitization policy.

## Problem Frame

The retained-query primitives already expose a truthful scope and health result, but the public exact-detail endpoint discards it. Legacy offset compatibility also composes multiple mutable cursor reads, and the API/UI each independently enforce the same sensitive-field boundary.

## Requirements

- R1. Public exact-detail responses carry additive retained scope and health metadata, including corrupt-prefix partiality.
- R2. A legacy v1 offset response is assembled from one serialized retained-store snapshot, even when its limit crosses the normal cursor-page bound.
- R3. Machine and Commands projections share one domain sanitization policy and preserve their respective output shapes.

## Scope Boundaries

- Preserve v1 offset defaults, bounds, ordering, filters, and public field names.
- Preserve the retained cursor query, count, lifecycle, and dashboard contracts already validated on this branch.
- Do not expose prompts, sessions, account identities, credentials, or capability-bearing URLs.

## Key Technical Decisions

- Add exact-detail metadata alongside the existing decision fields so clients retain their current response shape while gaining explicit retained health.
- Add a dedicated store-owned legacy-page read instead of iterating `DecisionQuery.list/2`; the GenServer call provides the one mutable-state boundary.
- Move the existing allowlists and URL/identity checks to `Aiur.DecisionSanitizer`; API and UI layers only translate safe values into their atom- or string-keyed response shapes.

## Implementation Units

### U1. Preserve exact-detail retained metadata

**Goal:** Return retained scope and health from `DecisionApi.get/2` through the existing controller response.

**Requirements:** R1

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/decision_api.ex`
- Test: `src/test/aiur/decision_api_test.exs`
- Test: `src/test/aiur_web/controllers/decision_api_controller_test.exs`

**Approach:** Reuse the list response's scope/health encoding for direct lookup without nesting or replacing the existing encoded Decision.

**Test scenarios:**
- A healthy direct lookup reports retained scope and available health.
- A corrupt-prefix lookup reports partial health and its reason through both the facade and controller.

**Verification:** A direct-detail client can distinguish complete data from a validated retained prefix.

### U2. Read v1 offset pages atomically

**Goal:** Serve legacy offset compatibility from one retained-store call and one immutable current-order view.

**Requirements:** R2

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur/decision_api/legacy_pagination.ex`
- Modify: `src/lib/aiur/decision_store.ex`
- Modify: `src/lib/aiur/decision_store/retained_snapshot.ex`
- Create: `src/lib/aiur/decision_store/retained_snapshot/legacy_page.ex`
- Test: `src/test/aiur/decision_api_test.exs`
- Test: `src/test/aiur/decision_query_test.exs`

**Approach:** Keep the legacy parameter contract at its existing boundary, then pass its normalized query, offset, and page size to one store-owned snapshot collector.

**Test scenarios:**
- A limit above the cursor-page bound preserves current ordering, total, and next offset.
- A mutation scheduled after the legacy snapshot call cannot alter or duplicate a response that spans the former internal-page boundary.
- Invalid legacy bounds and cursor-only filters remain rejected.

**Verification:** One v1 response has one retained snapshot identity and never composes mutable cursor reads.

### U3. Share the Decision sanitization policy

**Goal:** Make public API and Commands rows derive sensitive-field handling from one domain module.

**Requirements:** R3

**Dependencies:** U1

**Files:**
- Create: `src/lib/aiur/decision_sanitizer.ex`
- Modify: `src/lib/aiur/decision_api/public_projection.ex`
- Modify: `src/lib/aiur_web/operator_control_center/decision_presenter.ex`
- Delete: `src/lib/aiur_web/operator_control_center/decision_sanitizer.ex`
- Test: `src/test/aiur/decision_api_test.exs`
- Test: `src/test/aiur_web/operator_control_center/decision_provider_test.exs`

**Approach:** Move the existing conservative agent-ID, ticket URL, artifact URL, provenance, and lifecycle allowlists intact. Keep endpoint-specific key encoding and timestamp conversion outside the sanitizer.

**Test scenarios:**
- Safe values remain visible in both surfaces with their expected key styles.
- Credential-shaped identities, unsafe URLs, capability query/fragment values, sessions, and account fields are absent from both surfaces.

**Verification:** Security-sensitive projection rules have one implementation and cross-surface parity coverage.

## Risks & Dependencies

| Risk | Mitigation |
| --- | --- |
| Additive detail metadata conflicts with established clients | Preserve all existing top-level Decision fields and only add `scope` and `health`. |
| Legacy offset work accidentally weakens bounded cursor reads | Keep it on a dedicated internal store API; cursor callers continue using `DecisionQuery`. |
| Sanitizer move changes non-security presentation fields | Characterize current safe projections and compare API/UI output in focused tests. |

## Sources & References

- Exact-head review: [#1088 comment](https://github.com/aiur-team/aiur/issues/1088#issuecomment-4974997031)
- Earlier query and presentation repairs: `docs/plans/2026-07-14-001-fix-retained-decision-query-rework-plan.md`, `docs/plans/2026-07-14-002-fix-retained-decision-presentation-security-plan.md`
