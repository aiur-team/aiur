# BO: DASH-015 — Render authenticated provider meters

**Kind:** executable

**Provenance:** planned in plan v1 after companion-boundary review

**Complexity:** 3 — Responsive protected composition across two provider-meter adapters

**Risk:** high

**Phase hint:** 7

**Depends on:** DASH-003, DASH-013, DASH-020, DASH-021

**Serializes with:** DASH-005, DASH-007, DASH-022, DASH-027, DASH-028, DASH-031, DASH-034 — shared `DashboardLive`/CSS/summary layout

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-015

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:3`, `model:codex-gpt-5.6-terra`, `phase:7`, `build-lane:accounting`; never `agent:todo`

**Build Order membership:** member of the consolidated Build Order (operator decision 2026-07-13)

## Outcome

Authenticated Executors see responsive Codex and Claude account-meter cards
with exact provider/backend/account generation, actual auth mode and plan tier,
supported quota/rate/credit windows, reset times, coverage, health, and
freshness. All other connections see only DASH-021's content-free locked state.

## Context and evidence

The refreshed prototype shows static Codex/Claude session and weekly meters
beside an unexplained dollar total. Provider quota cards, usage accounting, and
the nonfinancial Aiur summary degrade independently. DASH-013/020 supply the
meter facts, DASH-021 supplies the non-bypassable auth boundary, DASH-031 owns
token/cost presentation, and DASH-022 owns run status.

## Scope

- Consume protected meter facts only through DASH-021 facades. A denied
  connection renders its content-free `authentication_required` state and
  never queries, subscribes to, caches, assigns, or receives meter values.
- Render Codex and Claude cards from DASH-020/013 through DASH-012 semantics: exact provider/backend/generation, auth mode, sourced plan/tier, supported subscription windows or API controls, reset timestamps, per-window freshness/health, stale LKG, partial, unsupported, empty-supported, loading, and hard error.
- Show actual plan/tier only from the meter snapshot's exact known provider,
  backend, and account generation. Unknown, rotated, stale, mixed, or mismatched
  identity remains explicit and never borrows the current login's tier.
- On mount/reconnect, fetch current protected snapshots after authorization,
  then subscribe through DASH-021 to daemon-owned meter updates. Coalesce
  render/screen-reader announcements and isolate one provider failure from the
  healthy card.
- Reflow every plan, window, limit, reset, coverage disclosure, and provider
  state at 320/390/768/960/desktop and 200% text zoom, accounting for DASH-003
  navigation/safe-area offsets. Use semantic meters and 44px controls.

## Non-goals

- Render token/cost totals or drill-down, or compute the Aiur live/remaining/
  progress/elapsed/ETA summary; DASH-031 and DASH-014/022 own those surfaces.
- Ingest meters, persist usage, apply prices, allocate subscription fees, call
  billing APIs, or redesign Analytics.
- Fetch providers per browser, correlate tier without exact generation, show
  fake subscription bars for API accounts, or weaken DASH-021.

## Existing owner and reuse target

Add protected provider-meter presenters/components to DASH-003's Units page
beside DASH-022 and DASH-031. Consume DASH-013/020 only through DASH-021, reuse
DASH-012 health vocabulary, and keep provider protocol logic outside `AiurWeb`.

## Contract and invariants

- Every value names provider, backend, auth mode, account generation, source,
  window/limit kind, coverage, health, observation time, and freshness.
- Actual tier and quota facts attach only to their exact provider/backend/known
  generation. Unknown, rotated, partial, stale, unsupported, and mismatch are
  explicit.
- Protected facts enter the connection only through DASH-021 authorization. Locked mode contains no hidden protected values.
- Unsupported, partial, stale, error, empty-supported, unknown, mismatch, zero,
  and healthy values are distinct.
- DOM and visual order match. Meter names, values, bounds, resets, coverage,
  unavailable reasons, and disclosures are programmatically exposed.

## Refreshable implementation notes

- Refresh final DASH-021 facade/locked contract and provider-meter schemas at
  pickup. Build presenters over synthetic fixtures before wiring subscriptions.
- Format reset times with machine-readable `<time datetime>` and useful absolute/relative copy. Coordinate shared container/CSS with DASH-022 via serialization.

## Acceptance and verification

### Agent gate

- Presenter/component tests cover exact generation/tier, account rotation,
  API-key/subscription modes, every provider/window health state, reset/expiry,
  full/patch/tombstone behavior, and live updates.
- DASH-021 integration tests prove denied mode never invokes protected meter
  providers or contains account/auth-mode, plan/tier, quota/rate/credit/spend-
  control, percentage/limit/reset, freshness, LKG, or hidden serialized values.
- Browser/a11y tests cover meter semantics, reset times, disclosures, focus,
  announcement coalescing, light/dark/reduced motion, 44px targets, 200% zoom,
  all breakpoints, safe-area offsets, and no clipping.

### At-merge gate

- Rebase all four prerequisites and the resolved configured integration target;
  sequence shared Units/CSS ownership and pass provider-meter, auth/security,
  accessibility, performance, and full CI suites.

### Human/manual evidence

- From the Executor repository root, compare Codex/Claude subscription, API-key,
  partial/stale, exact-generation, account-switched, unsupported, and locked
  variants at desktop and 390px/200%. Verify denied rendered source/events
  contain no protected meter values.

## Failure, security, migration, and accessibility cases

- Each provider failure degrades only its card and preserves safe generation-
  qualified LKG with timestamps; no failure resets quota to zero or unlimited.
- Protected data never enters unauthenticated HTML, assigns, events, caches, logs, prompts, bug reports, or generic APIs. Tests/evidence use synthetic values only.
- No stored-data migration; prerequisite schemas own compatibility.
- All metrics, windows, coverage, errors, disclosures, and controls are named,
  non-color-dependent, keyboard/touch reachable, and screen-reader bounded.

## Surfaces

- Reads: DASH-013 Claude meters, DASH-020 Codex meters, DASH-021 protected
  query/subscription/locked contract, and DASH-003 Units composition.
- Writes: protected provider-meter presenters/components, authorized
  subscriptions, responsive CSS, and tests.
- Contracts: exact-generation provider-meter cards and responsive/accessibility/
  live-update behavior.

## Sibling boundaries and open gates

DASH-022 owns the adjacent nonfinancial run summary and DASH-031 owns usage/
cost accounting and tier annotations on those contributor groups. The UI
tickets serialize on shared composition/CSS without a semantic dependency.
This ticket never changes Build Order membership, progress, critical path, ETA,
or acceptance.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-015`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
