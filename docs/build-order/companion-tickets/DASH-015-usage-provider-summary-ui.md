# DASH-015 — Render authenticated usage and provider summary

**Kind:** executable

**Provenance:** planned in plan v1 after companion-boundary review

**Complexity:** 4 — Responsive composition across independently degrading usage, pricing, and two provider-meter adapters

**Risk:** high

**Depends on:** DASH-003, DASH-010, DASH-011, DASH-013, DASH-020, DASH-021

**Serializes with:** DASH-022 and shared Units summary, `DashboardLive`, provider-card, drill-down, and CSS changes

**External gate:** `GATE-OCC-PREDECESSOR-BASELINE` — resolve before dispatch

**Requirements:** DREQ-015

**Researched at:** `9849f32963c2a65367bce565b3f5ede3777c218f`

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Authenticated Executors see responsive Codex and Claude usage/provider cards with tokens, separately comparable estimate bases, actual generation-matched plan/quota facts, retained coverage, freshness, and bounded drill-down; all other connections see only DASH-021's content-free locked state.

## Context and evidence

The refreshed prototype shows static Codex/Claude meters and a `$50.47` total that combines unexplained costs. The user requires token and estimate totals by ticket, agent family, backend, model, and total run/build, across subscription and API-token modes, including Claude Remote Control. DASH-010/011/013/020 supply the facts and DASH-021 supplies the non-bypassable auth boundary. DASH-022 separately renders the nonfinancial Aiur run summary.

## Scope

- Consume protected facts only through DASH-021 facades. A denied connection renders its content-free `authentication_required` state and never queries, subscribes to, caches, assigns, or receives provider/usage values.
- Render Codex and Claude cards from DASH-020/013 through DASH-012 semantics: exact provider/backend/generation, auth mode, sourced plan/tier, supported subscription windows or API controls, reset timestamps, per-window freshness/health, stale LKG, partial, unsupported, empty-supported, loading, and hard error.
- Render DASH-011 current-run tokens and monetary groups with totals and bounded drill-down by ticket, agent family, backend, exact model, currency, basis, and opaque provider-account generation. Preserve total tokens and provider split.
- Allow an explicit typed Build Order member set as a reusable query/component scope, but Units defaults to and labels `this run`; never infer `this build` from labels, render state, or currently visible rows.
- Join usage to actual tier only on exact known provider, backend, and `provider_account_generation`. Unknown generation yields tier `unknown`; multi-generation group yields `mixed`; known mismatch is visibly unjoined. Never fall back to provider/backend/current login/render order.
- Display `provider_reported_estimate` and `api_equivalent_estimate` in separate basis/currency/generation buckets. Never sum unlike buckets or call either billed/actual spend.
- For subscription usage, show API-equivalent dollars with `*` and an accessible information popover explaining the estimate. Show actual tier beside it only after the exact-generation join.
- Surface DASH-010 Remote Control coverage within Claude usage and distinguish missing/partial coverage from zero.
- On mount/reconnect, fetch current protected snapshots after authorization, then subscribe through DASH-021 to daemon-owned ledger/meter updates. Coalesce render and screen-reader announcements; isolate one provider/query failure from healthy regions.
- Reflow every meter, reset, disclosure, group, and drill-down at 320/390/768/960/desktop and 200% text zoom, accounting for DASH-003 navigation/safe-area offsets. Use semantic meters/progress and 44px interactive targets.

## Non-goals

- Render or compute the Aiur live/remaining/progress/elapsed/ETA summary; DASH-014/022 own it.
- Ingest usage/meters, persist ledger data, apply prices, allocate subscription fees, call billing APIs, or redesign Analytics.
- Fetch providers per browser, combine unlike bases/currencies/generations, correlate tier without exact generation, show fake subscription bars for API accounts, or weaken DASH-021.

## Existing owner and reuse target

Add protected provider/usage presenters and components to DASH-003's Units page beside DASH-022's nonfinancial summary. Consume DASH-010/011/013/020 only through DASH-021, reuse DASH-012 health vocabulary, and keep financial/accounting policy outside `AiurWeb`.

## Contract and invariants

- Every value names scope, source/basis, coverage, currency/generation, health, and freshness where relevant. `this run` and explicit `this build` are never interchangeable.
- Unlike bases, currencies, and account generations remain separate. Unknown cost is not `$0.00`.
- Subscription API-equivalent estimates always carry `*` and explanatory popover. Actual tier appears only for exact provider/backend/known-generation match; unknown, mixed, and mismatch are explicit.
- Protected facts enter the connection only through DASH-021 authorization. Locked mode contains no hidden protected values.
- Unsupported, partial, stale, error, empty, unknown, mixed, mismatch, zero, and healthy values are distinct.
- DOM and visual order match. Meter names, values, bounds, resets, coverage, unavailable reasons, and disclosure controls are programmatically exposed.

## Refreshable implementation notes

- Refresh final DASH-021 facade/locked contract and provider/group schemas at pickup. Build presenters over synthetic fixtures before wiring subscriptions.
- Keep grouping/detail pagination bounded and keyed; large runs must not create unbounded DOM.
- Format reset times with machine-readable `<time datetime>` and useful absolute/relative copy. Coordinate shared container/CSS with DASH-022 via serialization.

## Acceptance and verification

### Agent gate

- Presenter/component tests cover current-run and explicit-build scope, every cost basis/currency/coverage/generation, exact tier match, unknown/mixed/mismatch, API-key/subscription modes, all meter health states, Remote Control coverage, grouping reconciliation, and live updates.
- Join tests prove provider/backend-only matches fail closed, current tier cannot attach to historical usage from another generation, and mixed/unknown groups expose no constituent tier.
- DASH-021 integration tests prove denied mode never invokes protected providers or contains token, dollar, group, account/auth-mode, plan/tier, quota/rate/credit/spend-control, percentage/limit/reset, freshness, LKG, or serialized hidden values.
- Browser/a11y tests cover meter semantics, reset times, keyboard/touch drill-down/popover, focus restore, announcement coalescing, light/dark/reduced motion, 44px targets, 200% zoom, all breakpoints, safe-area offsets, and no clipping.

### At-merge gate

- Rebase all six prerequisites and the resolved configured integration target; sequence with DASH-022/shared Units/CSS ownership and pass accounting, Remote Control coverage, provider meters, auth/security, accessibility, performance, and full CI suites.

### Human/manual evidence

- From the Executor repository root, compare subscription, API-key, partial/stale, Remote Control-inclusive, exact-generation, account-switched, mixed-generation, and locked variants. Verify totals/disclosures/tier joins, 390px/200% layout, and absence of protected values in denied rendered source/events.

## Failure, security, migration, and accessibility cases

- Each provider/query failure degrades only its region and preserves safe generation-qualified LKG with timestamps; no failure resets usage/quota to zero or unlimited.
- Protected data never enters unauthenticated HTML, assigns, events, caches, logs, prompts, bug reports, or generic APIs. Tests/evidence use synthetic values only.
- No stored-data migration; prerequisite schemas own compatibility.
- All metrics, scopes, bases, coverage, errors, disclosures, groups, and controls are named, non-color-dependent, keyboard/touch reachable, and screen-reader bounded.

## Surfaces

- Reads: DASH-010 Remote usage coverage, DASH-011 grouped usage/estimates, DASH-013 Claude meters, DASH-020 Codex meters, DASH-021 protected query/subscription/locked contract, DASH-003 Units scope.
- Writes: protected usage/provider presenters/components, bounded drill-down/popover, authorized subscriptions, responsive CSS and tests.
- Contracts: exact-generation tier composition, authenticated usage/provider UI states, estimate disclosure, responsive/accessibility/live-update behavior.

## Sibling boundaries and open gates

DASH-022 owns the adjacent nonfinancial run summary; the two UI tickets serialize on shared composition/CSS without a semantic dependency. Prerequisites own every value and policy. A future Build Order view may pass explicit member identities, but this ticket never changes Build Order membership, progress, critical path, ETA, or acceptance.
