---
title: Responsive Units Interface
type: feat
status: active
date: 2026-07-17
origin: docs/brainstorms/2026-07-12-build-order-requirements.md
---

# Responsive Units Interface

## Summary

Replace the legacy Fleet projection on the dashboard index with a server-backed Units presentation that consumes DASH-016, extends the existing payload reload path, and reuses BO-018 ticket context. Keep filters canonical in the URL and make the same semantic row facts and named actions usable as a table on wide screens and reflowed cards on narrow screens.

---

## Problem Frame

The current Fleet view owns lifecycle-derived buckets, client-local filter state, clickable table rows, and a filesystem-backed log modal. Those behaviors cannot represent the accepted overlapping Units policy, survive shared navigation, or provide the accessible all-state ticket inspection required by DREQ-003.

---

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input — un-validated bets that should be reviewed before implementation proceeds.*

- The dashboard index remains the Units route, preserving existing Fleet URLs without a redirect.
- The existing payload cache/reload scheduler is the presentation boundary for Units snapshots; LiveView subscribes to accepted membership and activity updates but does not create a second catalog process.
- Until DASH-027 provides a safe conversation destination, the named Chat action remains truthfully unavailable. A separately named Agent log action may preserve the existing running-agent compatibility path while the Units row contract remains free of workspace paths and raw payloads.
- DOM-stable typed-identity keys plus LiveView patching are sufficient for focus preservation when a row remains visible; no reorder animation is introduced.

---

## Requirements

- **DREQ-003.** Render one responsive Units view with URL/count/zero-result filters, exact source-backed facts with explicit unknowns, named row actions, and the reusable all-state ticket context.
- **DREQ-016.** Treat `UnitsRow`, `UnitsPolicy`, and `UnitsURL` as the sole row, predicate/count, and URL-state authorities; the LiveView must not rederive lifecycle policy.
- **BOREQ-011.** Reuse repository-qualified, bounded, read-only ticket detail/history presentation with trusted GitHub, Chat, and Commands capability handling and accessible focus behavior.
- Preserve URL selection across refresh, copied links, and browser history; live catalog changes may change results but may not rewrite a valid selection.
- Preserve safe existing dashboard behavior, including Commands navigation and the explicitly temporary running-agent log path, without performing GitHub or workspace-log reads during row rendering.
- Expose all facts and actions at 320, 390, 768, and 960 CSS pixels and at 200% zoom without page-level horizontal scrolling; named interactive targets are at least 44px and unknown progress omits `aria-valuenow`.
- Coalesce live status announcements, retain focus for stable visible identities, and avoid motion that could move focus or violate reduced-motion preferences.

**Origin acceptance examples:** Example 7 (keyboard context navigation and focus restoration), Example 8 (390px, 200% zoom, 44px actions)

---

## Scope Boundaries

- Do not redefine DASH-016 membership, lifecycle, condition predicates, counts, URL validation, or progress facts.
- Do not add pause/resume, capacity writes, usage/cost, Build Order relationships, a new conversation destination, or provider-specific placeholder data.
- Do not parse workspace logs, expose raw paths/provider payloads, fetch tracker data during render, or weaken BO-018 trusted repository and URL checks.
- Do not copy the prototype's client-side state machine, exclusive buckets, clickable `<tr>`, fake remote links, or undersized essential text.

### Deferred to Follow-Up Work

- Safe read-only conversation navigation: DASH-027 activates the named Chat capability seam; the separately labelled Agent log compatibility action can then be retired.
- Runtime unit and capacity controls: DASH-005/DASH-028 may extend the explicit row action seam after their write contracts land.
- Build Order-specific context relationships: remain owned by the Build Order composition rather than the reusable base context used here.

---

## Context & Research

### Relevant Code and Patterns

- `AiurWeb.OperatorControlCenter.UnitsRow`, `UnitsPolicy`, and `UnitsURL` already provide pure typed projections, overlapping policy/counts, replacement semantics, provenance, trusted tracker URLs, and versioned validated URL state.
- `AiurWeb.OperatorControlCenter.PayloadLoader` already bounds and coalesces dashboard provider work outside rendering; `DashboardLive` already handles URL-backed Commands filters and periodic runtime refreshes.
- `AiurWeb.OperatorControlCenter.TicketContext` and `AiurWeb.BuildOrder.TicketContextPresenter` are the accepted BO-018 semantic context surface. `TicketDetailCache` and `TicketHistoryProvider` provide bounded on-demand state and update subscriptions.
- `FleetTable` and `FleetFilters` are the replacement surface. Their useful presenter/runtime formatting may be retained, but their exclusive filter policy, clickable row, and narrow controls are not contracts.
- The authenticated browser fixture already exercises the route shell and ticket context with Playwright; extend it with deterministic Units rows and live updates rather than introducing another harness.

### Institutional Learnings

- The approved Build Order pack requires data ownership to stay in daemon projections and presentation joins to remain pure. No applicable `docs/solutions/` note exists in this checkout.
- DEC-015 places DASH-003 in consolidated lane L2 following BO-018. BO-018, DASH-001, and DASH-016 are merged into the current `develop` target, so this plan extends their accepted integration head rather than stacking provisional contracts.

### External References

- None. The repository's accepted Phoenix LiveView patterns and pinned planning evidence fully define this ticket's behavior.

---

## Key Technical Decisions

- Extend the dashboard payload boundary with a Units adapter that joins recoverable membership and activity with already-loaded normalized status/issue facts, then calls the pure DASH-016 projection. This keeps provider I/O and failure handling out of render while avoiding a duplicate lifecycle policy.
- Decode filter params in `handle_params` and generate every scope/chip/reset transition through `UnitsURL`; do not retain a second client or socket-owned filter truth.
- Use one semantic table whose rows reflow into labelled card sections under CSS breakpoints. Lead with identity/title and lifecycle/progress/evidence, group execution metadata and waiting context second, and place named actions last. DOM and visual order remain identical, every row action is an explicit button/link, and rows themselves remain non-interactive.
- Represent progress, freshness, provider degradation, and unknown facts explicitly. Only numeric progress receives determinate meter semantics; unknown progress remains labelled and omits a fabricated numeric value.
- Open BO-018 context only from an explicit inspection event resolved against the current server snapshot. Provider reads occur when opening or updating the selected context, never from component rendering.
- Key rows and controls from repository-qualified typed identities using opaque server-derived tokens. Stable identities retain their DOM controls across payload patches; announcements use one atomic live region fed by the coalesced reload path.
- Add focus-origin restoration to the shared ticket-context dialog hook because BO-018 deliberately assigns that responsibility to callers and DASH-003 is the first row-origin integration. Restore the originating control when it remains connected; otherwise focus the Units heading as a stable fallback.

---

## Open Questions

### Resolved During Planning

- **Does DASH-003 need a new route?** No. DASH-001 already defines the dashboard index as Units, so replacing Fleet in place preserves the existing route and links.
- **Should the LiveView calculate condition buckets or replacement retention?** No. DASH-016 owns both; the UI only projects its selected rows and counts.
- **Can BO-018 context be copied into a dashboard-specific modal?** No. The accepted component, presenter, caches, trust policy, and focus lifecycle are consumed directly with only a thin Units adapter.
- **Should a branch dependency remain?** No. BO-018 (#1105), DASH-001 (#1108), and DASH-016 (#1122) are merged into the configured `develop` target.

### Deferred to Implementation

- Exact normalized status fields available for backend/model/effort/lane vary by source. The adapter will preserve source values when present and render explicit unknowns otherwise; it will not invent or widen a trusted source contract merely for display completeness.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification.*

```text
membership + activity + normalized dashboard payload
                       |
                       v
             DASH-016 UnitsRow snapshot
                       |
            PayloadLoader cache/reload
                       |
       UnitsURL selection -> UnitsPolicy projection
                       |
        semantic table / narrow card reflow
                       |
 explicit Inspect -> BO-018 detail/history/context
```

---

## Implementation Units

### U1. Units snapshot and URL composition

**Goal:** Feed the dashboard a failure-aware DASH-016 snapshot and make validated URL state the only filter selection authority.

**Requirements:** DREQ-003, DREQ-016

**Dependencies:** Merged DASH-001/DASH-016

**Files:**
- Create: `src/lib/aiur_web/operator_control_center/units_presenter.ex`
- Modify: `src/lib/aiur_web/operator_control_center/payload_loader.ex`
- Modify: `src/lib/aiur_web/live/dashboard_live.ex`
- Test: `src/test/aiur_web/operator_control_center/units_presenter_test.exs`
- Test: `src/test/aiur_web/live/dashboard_live_test.exs`

**Approach:**
- Adapt accepted membership, activity, normalized status/issue, and Decision facts into `UnitsRow.snapshot/1` outside render, preserving source health and last-known-good semantics.
- Subscribe the LiveView to membership/activity changes and route them through the existing bounded reload scheduler.
- Decode index params with `UnitsURL`, use `UnitsPolicy.project/2` for selected rows/counts, and push versioned patches for scope, independent conditions, and reset.

**Patterns to follow:**
- `PayloadLoader` coalescing and Decision URL handling in `DashboardLive`.
- Existing `UnitsRow`, `UnitsPolicy`, and `UnitsURL` tests as executable contracts.

**Test scenarios:**
- Happy path: every scope and independent condition combination projects the DASH-016 rows and overlapping counts without additive wording.
- Integration: copied URL, refresh, valid/invalid params, reset, and browser back/forward reproduce the validated selection.
- Integration: insert/update/terminal-retention payload changes preserve the selection and stable row identity.
- Error path: degraded or unavailable sources remain visibly named and never become a healthy empty fleet.

**Verification:** The LiveView contains no independent lifecycle predicates or filter state machine, and payload reloads do not rewrite valid URL selection.

---

### U2. Responsive semantic Units presentation

**Goal:** Replace Fleet with accessible, source-honest Units rows that remain complete from desktop through narrow reflow.

**Requirements:** DREQ-003, DREQ-016

**Dependencies:** U1

**Files:**
- Create: `src/lib/aiur_web/components/operator_control_center/units_filters.ex`
- Create: `src/lib/aiur_web/components/operator_control_center/units_table.ex`
- Modify: `src/lib/aiur_web/live/dashboard_live.ex`
- Modify: `src/priv/static/dashboard.css`
- Test: `src/test/aiur_web/components/operator_control_center/units_filters_test.exs`
- Test: `src/test/aiur_web/components/operator_control_center/units_table_test.exs`
- Test: `src/test/aiur_web/live/dashboard_live_test.exs`

**Approach:**
- Render single-select scope buttons, independent condition chips with predicate counts, an overlap explanation, a named zero-result reset, and a coalesced atomic status announcement.
- Distinguish initial loading, healthy empty catalog, valid-filter empty results, stale last-known-good rows, and named unavailable catalog states before rendering rows.
- Render one non-clickable semantic table with explicit inspection and safe available actions; reflow each table row into a labelled card layout without changing DOM order or the identity/title → state/progress/evidence → metadata/context → actions hierarchy.
- Surface typed identity, lifecycle/condition text, backend/agent/model/effort/complexity/lane, evidence, progress source/freshness, runtime, waiting/blocking context, open Commands, and provider health with explicit unknown/stale language.
- Keep controls at least 44px, show visible focus, avoid row-reorder animation, and omit `aria-valuenow` for unavailable progress.

**Patterns to follow:**
- Existing dashboard shell/card tokens and narrow-table reflow CSS.
- BO-018 ticket-context semantic labels and trusted capability links.

**Test scenarios:**
- Happy path: complete and partial rows render all normalized facts and named actions without a clickable `<tr>`.
- Edge case: unknown model/progress/freshness and stale/degraded providers render explicit text without fake values or placeholder models.
- Accessibility: selected scopes/chips expose state, progress semantics distinguish known from unavailable, and status changes use a single bounded live region.
- Security: rendered rows contain no workspace path, raw log/provider payload, unsafe tracker URL, or ambient account data.

**Verification:** Component and LiveView tests prove semantic completeness, safe links, stable identifiers, and explicit degradation at every presentation state.

---

### U3. Shared ticket context, focus, and browser evidence

**Goal:** Make explicit row inspection reuse BO-018 context and prove the responsive/live-update interaction in a real browser fixture.

**Requirements:** DREQ-003, BOREQ-011

**Dependencies:** U1, U2, merged BO-018

**Files:**
- Modify: `src/lib/aiur_web/live/dashboard_live.ex`
- Modify: `src/priv/static/ticket-context-dialog-hook.js`
- Modify: `src/test/browser/fixture_server.exs`
- Create: `src/browser/tests/units.browser.spec.mjs`
- Modify: `src/browser/tests/ticket-context.browser.spec.mjs`
- Test: `src/test/aiur_web/live/dashboard_live_test.exs`

**Approach:**
- Resolve explicit inspection tokens only against the current server snapshot, request the accepted bounded detail/history providers, and present BO-018 context with truthful GitHub, Chat, and Commands capability availability. Ignore provider updates whose typed identity is no longer selected.
- Keep Chat separately named and unavailable until DASH-027 supplies its destination. Preserve the current running-agent behavior only through a distinctly labelled Agent log compatibility action when safely available; never add its local payload model to Units rows.
- Capture the originating control in the dialog hook and restore focus after close when the control remains available, falling back to the Units heading when a live update removed it.
- Add deterministic fixture rows and update events to exercise keyboard/touch inspection, live focus persistence, announcements, URL history, reduced motion, zoom, and responsive overflow.

**Patterns to follow:**
- `TicketContextLive` browser fixture and `ticket-context.browser.spec.mjs`.
- BO-018 detail/history provider subscription and presenter tests.

**Test scenarios:**
- Integration: keyboard and touch activate only named inspection/actions; closing context returns focus to the originating control.
- Integration: a live update to the same identity retains focused control and selection; if a filtered-out identity removes the origin control, dialog close falls back to the Units heading without animated reorder.
- Accessibility: 320/390/768/960/desktop widths, 200% zoom, reduced motion, and 44px targets have no page-level horizontal overflow or hidden facts/actions.
- Security: initial row/context render performs no GitHub or workspace-log read, and unsafe/unavailable capabilities remain disabled or absent.

**Verification:** Focus, URL history, responsive layout, announcement coalescing, and no-render-I/O expectations pass in focused LiveView/component/browser coverage.

---

## System-Wide Impact

- **Interaction graph:** Membership/activity PubSub invalidates the dashboard payload cache; URL params select a pure policy projection; explicit inspection alone reaches ticket detail/history providers.
- **Error propagation:** Provider failures become named unavailable/stale snapshot state, preserving last-known-good membership where supplied instead of collapsing to healthy empty UI.
- **State lifecycle risks:** Row replacement and live sorting can disturb focus; repository-qualified stable keys, no reorder animation, and origin restoration bound that risk.
- **API surface parity:** DASH-016 and BO-018 public APIs stay unchanged. Fleet components may remain temporarily for unrelated tests/manual fixtures but no longer define the production index contract.
- **Integration coverage:** Playwright proves LiveView patch behavior, URL history, touch/keyboard semantics, zoom, and CSS reflow that isolated component tests cannot establish.
- **Unchanged invariants:** Commands and safe tracker navigation remain read-only; the legacy running log modal stays a compatibility path; dashboard rendering does not own lifecycle, provider fetches, or workspace data.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Shared `DashboardLive`/CSS lane changes conflict with sibling dashboard work | Keep the diff localized to the accepted Units action seam, target current `develop`, and review the three-dot feature diff before push. |
| Source shapes omit desired metadata | Render explicit unknowns and preserve provenance; do not manufacture values or broaden unrelated daemon contracts. |
| Live patches replace focused nodes | Use stable identity-derived DOM keys, test same-identity updates in Playwright, and avoid animated reorder. |
| Ticket context accidentally performs provider work while rendering | Trigger reads only from mount/event/update handlers and test rendering with provider functions that fail if invoked. |
| Responsive table loses semantic or visual facts | Use one DOM order with CSS reflow and assert text/actions plus overflow at every required viewport and zoom level. |

---

## Documentation / Operational Notes

- Record focused component/LiveView/browser commands in the issue workpad and PR.
- The Executor-root real CLI/browser walkthrough remains the human/manual acceptance gate because agent workspaces may not run `scripts/aiurdev --test`.
- PR and CI target the authoritative `develop` integration branch and flow through DEC-015 lane L2.

---

## Sources & References

- **Origin document:** `docs/brainstorms/2026-07-12-build-order-requirements.md`
- Approved planning packet: `docs/build-order/README.md`, `docs/build-order/08-implementation-pointers.md`, `docs/build-order/05-technical-decisions.md`, `docs/build-order/02-dashboard-design-delta.md`, `docs/build-order/06-prototype-capability-audit.md`
- Execution amendment: `docs/build-order/11-execution-amendment.md` (DEC-015 lane L2)
- Related issues: #1105 (BO-018), #1108 (DASH-001), #1122 (DASH-016), #1110 (DASH-003)
- Related code: `src/lib/aiur_web/live/dashboard_live.ex`, `src/lib/aiur_web/operator_control_center/units_row.ex`, `src/lib/aiur_web/operator_control_center/units_policy.ex`, `src/lib/aiur_web/operator_control_center/units_url.ex`, `src/lib/aiur_web/components/operator_control_center/ticket_context.ex`
