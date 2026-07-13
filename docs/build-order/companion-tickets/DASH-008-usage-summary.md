# DASH-008 — Render shared run and build summary

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — Responsive accessible composition over accounting and meter contracts

**Risk:** medium

**Depends on:** DASH-006, DASH-007

**Requirements:** DREQ-008

**Researched at:** 3d67b7be722eb649f28088fc8d609dd7b75254c7

**Suggested labels:** `complexity:3`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Units renders truthful Codex, Claude, and Aiur summary cards for provider windows, tokens, spend, live/ticket counts, progress, elapsed time, and ETA with explicit run/build scope, provenance, coverage, freshness, and degradation.

## Context and evidence

The refreshed prototype moves usage into Units, adds Token/Spend labels and an Aiur Summary, but visually reorders DOM, clips at 390px, uses static meters, and drops total token detail. All sample values are illustrative. Production must preserve the user's requested groupings and make subscription/API/unsupported states distinct.

## Scope

- Render Aiur Summary first in both DOM and visual order, then provider cards, using DASH-006 summaries and DASH-007 meter snapshots without per-browser provider fetch.
- Show total and grouped run/build tokens/spend with scope, basis/coverage, observed time, and drill-down by ticket/model/agent family; retain total tokens even when provider cards split them.
- Show live units, remaining tickets, progress denominator/source, elapsed time, and ETA provenance only when real; otherwise show unavailable/unknown.
- Render subscription windows, API-key controls, unsupported, partial, stale LKG, hard error, loading/no-observation states, and accessible reset timestamps/meters.
- Reflow all facts/actions at 320/390/768/960/desktop without clipping; preserve theme, reduced motion, screen-reader order, and non-color semantics.

## Non-goals

- Ingest/persist usage, apply prices, fetch meters in LiveView, fabricate ETA/progress/spend/quota, or make this a Build Order completion dependency.
- Copy sample dollar/token values or CSS-only visual reorder.

## Existing owner and reuse target

Add shared OCC summary presenters/components to Units, consuming DASH-006/007 contracts and the shared shell. Keep provider/accounting logic outside `AiurWeb`.

## Contract and invariants

- Every number names scope, source/basis/coverage, and freshness where relevant.
- Unknown/unsupported/partial are distinct from zero and unlimited.
- DOM and visual reading order match; native/ARIA meter semantics expose names/values/resets.
- Selected Build Order IDs may scope `this build`, but plain Units uses explicit current-run scope.

## Refreshable implementation notes

- Resolve remaining subscription/membership/RC questions before final UI copy; component states can be built against all variants.
- Do not wait on Build Order implementation to ship current-run cards.

## Acceptance and verification

### Agent gate

- Presenter/component tests cover run/build scopes, every cost basis/coverage, subscription/API/unsupported meters, loading/empty/stale/error, progress/ETA unknown, grouping drill-down, and live updates.
- Browser/a11y tests cover DOM order, meters, reset timestamps, light/dark/reduced motion, 320/390/768/960, no clipping, keyboard/touch.

### At-merge gate

- Accounting/meter integrations, Units/dashboard, accessibility, and full current-base CI pass.

### Human/manual evidence

- Reviewer compares subscription/API/unsupported variants and verifies totals/groupings plus 390px layout.

## Failure, security, migration, and accessibility cases

- Financial/provider facts stay behind dashboard auth and contain no account identity.
- No stored-data migration here.
- Meters, coverage, scope, freshness, errors, and drill-down are accessible and non-color-dependent.

## Surfaces

- Reads: UsageSummary; ProviderMeterSnapshot; Units run/build selection.
- Writes: shared usage summary presenters/components/CSS/tests.
- Contracts: OCC summary UI state and scope vocabulary.

## Sibling boundaries and open gates

DASH-001 owns shell and DASH-002 owns Units rows. This UI is independent of Build Order acceptance; selected membership is an optional query input.

