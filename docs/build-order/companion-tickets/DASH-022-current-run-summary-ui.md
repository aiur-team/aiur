# BO: DASH-022 — Render accessible current-run summary

**Kind:** executable

**Provenance:** planned in plan v1 after presentation-boundary review

**Complexity:** 3 — Responsive accessible composition over one fixed nonfinancial run-summary contract

**Risk:** medium

**Phase hint:** 7

**Depends on:** DASH-003, DASH-014

**Serializes with:** DASH-005, DASH-007, DASH-015, DASH-021, DASH-023, DASH-027, DASH-028, DASH-031, DASH-034 — shared `DashboardLive`/CSS/summary layout

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-022

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:3`, `model:codex-gpt-5.6-terra`, `phase:7`, `build-lane:dashboard-ui`; never `agent:todo`

**Build Order membership:** member of the consolidated Build Order (operator decision 2026-07-13)

## Outcome

The Units page presents a live, responsive, accessible Aiur current-run summary with truthful counts, weighted progress and coverage, wall elapsed time, and formula-qualified ETA or an explicit unavailable reason.

## Context and evidence

The prototype combines an Aiur run summary with protected provider usage cards. The run summary itself is nonfinancial and has one canonical owner in DASH-014, so it can ship and remain visible under existing optional read-only dashboard policy without waiting for account/meter work. DASH-015 owns protected usage/provider presentation and shares only the visual summary region.

## Scope

- Render DASH-014 live, remaining, terminal-success, terminal-nonwork, unknown-state, and total counts with explicit scope.
- Render weighted progress denominator, known numerator/lower bound, unknown/defaulted/excluded weight, coverage, and exact percentage only when DASH-014 provides one.
- Render wall-clock elapsed time from DASH-014 and its formula-versioned ETA, sample/provenance/confidence, or exact unavailable reason. Never show summed agent runtime as wall elapsed.
- Read the current snapshot on mount/reconnect and subscribe to daemon-owned DASH-014 updates. Coalesce high-frequency renders and screen-reader announcements.
- Keep DOM and visual order consistent within the Units summary. Reflow at 320/390/768/960/desktop and 200% text zoom with DASH-001 safe-area/navigation offsets inherited through DASH-003.
- Use native/ARIA progress semantics only when values/bounds are known. Unknown progress omits `aria-valuenow` and names coverage/unavailability.
- Preserve a stale same-run last-known-good summary with freshness/health; new-run generation or unavailable facts cannot display the prior run as current.

## Non-goals

- Render tokens, cost, provider/account, plan/tier, quota/rate/credit/reset facts, subscription disclosures, or usage drill-down; DASH-015 owns those behind DASH-021.
- Compute counts/progress/elapsed/ETA, infer Build Order critical path, mutate runtime state, or fetch providers from the browser.
- Visually reorder protected cards around the summary with CSS in a way that changes assistive-technology order.

## Existing owner and reuse target

Add a focused Aiur run-summary presenter/component to DASH-003's Units page. Consume DASH-014 snapshot/health/PubSub and reuse DASH-001/DASH-003 responsive, theme, focus, and browser-harness contracts.

## Contract and invariants

- Every fact comes from DASH-014 with scope, generation, coverage, health, and freshness; the UI performs no aggregate math.
- Unknown, insufficient evidence, partial coverage, stale, unavailable, zero, and exact values remain distinct.
- Wall elapsed and ETA labels expose formula/provenance and never imply model-guessed certainty.
- Nonfinancial summary values remain independent of DASH-021 financial authorization and contain no protected data.
- DOM/visual order, accessible names, progress semantics, and coalesced announcements remain aligned across breakpoints.

## Refreshable implementation notes

- Refresh DASH-014 final field names and DASH-003 component seams at pickup; keep formatting in a presenter, not LiveView event handlers.
- Use bounded relative-time refresh driven by server state/clock without creating one high-frequency timer per browser fact.
- Coordinate the shared summary container and CSS with DASH-015; serialize changes rather than introducing a hard semantic dependency.

## Acceptance and verification

### Agent gate

- Presenter/component tests cover every count class, exact/partial/unknown progress, defaulted/excluded weight, elapsed, all ETA preconditions/reasons, stale LKG, generation transition, loading, empty, and hard error.
- LiveView tests cover initial/reconnect snapshot, PubSub update coalescing, focus stability, screen-reader announcement bounds, and absence of protected fields.
- Browser/a11y tests cover semantic progress, reduced motion, light/dark, 200% zoom, 320/390/768/960/desktop, safe-area offsets, and no clipping.

### At-merge gate

- Rebase on DASH-003/014 and sequence with DASH-015/shared summary CSS; run Units, run-summary, LiveView/PubSub, accessibility, browser, asset, performance, and full CI suites.

### Human/manual evidence

- From the Executor repository root, drive a synthetic real run through the dashboard, enable/disable ETA evidence, change weighted progress, and verify truthful update/reflow at desktop and 390px including optional unauthenticated read-only mode.

## Failure, security, migration, and accessibility cases

- DASH-014 failure preserves labelled same-run stale values or shows unavailable; it never falls back to zero, prior-run values, or summed agent time.
- The component receives no token, cost, account, plan, meter, credential, workspace, or provider payload data.
- No stored-data migration. Version presenter inputs with DASH-014 schema changes.
- All counts, coverage, progress, elapsed, ETA, health, and reasons are named, non-color-dependent, and screen-reader bounded.

## Surfaces

- Reads: DASH-014 snapshot/health/freshness/PubSub through DASH-003 Units composition.
- Writes: current-run presenter/component, live subscription/coalescing, responsive CSS and tests.
- Contracts: accessible nonfinancial current-run summary presentation.

## Sibling boundaries and open gates

DASH-015 owns protected usage/provider cards and drill-down; the two tickets serialize only on the shared summary container/CSS. DASH-021 cannot hide this ticket's permitted nonfinancial facts or accidentally attach protected data to them.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-022`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
