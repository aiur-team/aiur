---
title: "fix: Secure retained Decision presentation rework"
type: fix
status: completed
date: 2026-07-14
---

# fix: Secure retained Decision presentation rework

## Summary

Close the four exact-head P1s without broadening DASH-006. The retained provider will only expose safe artifact and provenance data, while the Commands UI will preserve an explicitly selected detail across filters and discard drafts whenever its command identity changes.

---

## Problem Frame

The query contract is green but the presentation boundary still leaks capability-bearing artifact URLs, truncates safe DASH-017 provenance, and lets stale list/filter or form state disagree with the authoritative retained detail.

---

## Requirements

- R1. List and exact-detail rows omit capability-bearing URL query or fragment material while retaining safe artifacts.
- R2. List and exact-detail rows preserve all safe canonical provenance fields and omit `session_id`.
- R3. A valid selected retained detail renders even when the active overview filter excludes its lifecycle.
- R4. Answer and revision drafts, confirmations, and idempotency state do not survive a same-ID Decision version or active-action change.

---

## Scope Boundaries

- Do not change retained pagination, cursor, count, or corrupt-prefix contracts already validated on this branch.
- Do not change stored Decision artifacts, schema, durable provenance capture, lifecycle authority, or command payload semantics.
- Do not expose raw prompts, sessions, accounts, credentials, or capability URLs.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur_web/operator_control_center/decision_presenter.ex` is the common row boundary for overview, retained list, and exact detail.
- `src/lib/aiur_web/components/operator_control_center/decision_inbox.ex` replaces overview data with selected exact detail before card rendering.
- `src/lib/aiur_web/live/dashboard_live.ex` refreshes a selected detail after payload changes; `decision_commands.ex` and `revision_commands.ex` own per-card ephemeral state.
- `src/test/aiur_web/operator_control_center/decision_provider_test.exs` uses a real retained store for provider-boundary parity; `src/test/aiur_web/live/dashboard_live_test.exs` has the mutable stale-overview test seam.

### External References

- None. Existing validation and presenter boundaries define the required behavior.

---

## Key Technical Decisions

- Omit URL artifacts with any query or fragment at the presenter boundary, rather than attempting to preserve an unknown capability parameter shape.
- Allowlist safe provenance fields explicitly, including schema/versioning and capture facts, while never forwarding `session_id`.
- Build the rendered inbox from the selected exact row plus the filtered nonselected list, so selection is route authority rather than a filter member.
- Tag action state with `{Decision version, active action ID}` and clear a state entry when the retained selection no longer matches that identity.

---

## Implementation Units

### U1. Sanitize provider-facing Decision rows

**Goal:** Make list and exact-detail presentation retain safe artifacts and complete safe provenance without forwarding capability or session material.

**Requirements:** R1, R2

**Dependencies:** None

**Files:**
- Modify: `src/lib/aiur_web/operator_control_center/decision_presenter.ex`
- Test: `src/test/aiur_web/operator_control_center/decision_provider_test.exs`

**Approach:** Filter URL artifacts with query or fragment data before any provider composition and extend the provenance allowlist with the canonical safe fields. Keep both provider entry points on `DecisionPresenter` so their rows remain equal apart from latency.

**Patterns to follow:** `safe_source/1`, `safe_actor/1`, and the existing real-store provider parity setup.

**Test scenarios:**
- Security: a retained HTTPS artifact containing capability material in a query or fragment is absent from both list and exact detail while a safe path artifact remains.
- Happy path: safe schema version, agent family, source, and capture time appear identically in list and detail; `session_id` is absent.

**Verification:** No capability string or session identifier reaches a provider result, and list/detail rows have presentation parity.

### U2. Keep route-selected detail independent of list filters

**Goal:** Render an authoritative selected detail even if its lifecycle moved outside the stale URL filter.

**Requirements:** R3

**Dependencies:** U1

**Files:**
- Modify: `src/lib/aiur_web/components/operator_control_center/decision_inbox.ex`
- Test: `src/test/aiur_web/live/dashboard_live_test.exs`

**Approach:** Replace or remove the selected ID from the overview list first, filter only the remaining rows, then prepend the selected retained row for card/detail rendering.

**Patterns to follow:** Existing same-ID replacement behavior and direct retained-detail routing tests.

**Test scenarios:**
- Regression: an overview row is open, exact retained detail is resolved, and `/decisions/:id?filter=open` still renders the resolved selection without an empty-state message.
- Edge case: a same-ID selected detail is rendered once, with no duplicate card.

**Verification:** Lifecycle filters constrain unselected list membership only; an exact route remains visible and actionable according to its retained state.

### U3. Scope command drafts to retained Decision identity

**Goal:** Clear answer and revision state whenever a selected same-ID detail changes version or active action.

**Requirements:** R4

**Dependencies:** U2

**Files:**
- Modify: `src/lib/aiur_web/live/dashboard_live.ex`
- Modify: `src/lib/aiur_web/operator_control_center/decision_commands.ex`
- Modify: `src/lib/aiur_web/operator_control_center/revision_commands.ex`
- Test: `src/test/aiur_web/live/dashboard_live_test.exs`

**Approach:** Store an identity marker beside ephemeral form and idempotency state, then remove mismatched state during retained-detail refresh before rendering the new version.

**Patterns to follow:** `assign_selected_decision/2`, `reload_view/1`, and `VersionedDetailStore` in the LiveView tests.

**Test scenarios:**
- Regression: after an answer draft and confirmation are entered, a same-ID v2 refresh removes them; the newly confirmed submit uses v2.
- Regression: after a revision draft and confirmation are entered, an active-action/version refresh removes them; the newly confirmed submit uses current version and action ID.

**Verification:** No form selection, destructive confirmation, or idempotency key can cross a Decision identity boundary.

---

## System-Wide Impact

- **Interaction graph:** retained store -> provider -> presenter -> Dashboard LiveView uses one safe row shape for overview, list, and exact detail.
- **State lifecycle risks:** a refresh must clear only stale same-ID action state, not unrelated cards or an unchanged draft.
- **Unchanged invariants:** query bounds, canonical counts, persistence, and provenance capture remain unchanged.

---

## Risks & Dependencies

| Risk | Mitigation |
| --- | --- |
| Overbroad artifact filtering hides normal evidence | Keep path artifacts and plain HTTPS URLs; remove only query/fragment-bearing URL values. |
| Refresh clears a valid draft | Compare both retained version and active action before clearing. |

---

## Sources & References

- Exact-head review: [#1088 comment](https://github.com/aiur-team/aiur/issues/1088#issuecomment-4970590437)
- Prior retained-query rework: `docs/plans/2026-07-14-001-fix-retained-decision-query-rework-plan.md`
