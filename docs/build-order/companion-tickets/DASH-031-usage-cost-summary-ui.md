# DASH-031 — Render authenticated usage and cost summary

**Kind:** executable

**Provenance:** planned in plan v1 after the shipped-dashboard capability re-audit

**Complexity:** 4 — Protected responsive composition, exact reconciliation, live scopes, and bounded drill-down

**Risk:** high

**Depends on:** DASH-003, DASH-010, DASH-013, DASH-020, DASH-021, DASH-025, DASH-029, DASH-030

**Serializes with:** DASH-005, DASH-007, DASH-015, DASH-022, DASH-027, DASH-028, DASH-034 — shared dashboard composition and responsive CSS

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-031

**Researched at:** `9849f32963c2a65367bce565b3f5ede3777c218f`

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Authenticated Executors see live token and API-equivalent estimate totals for
`this run` or an explicit selected-build scope, reconciled by ticket, provider,
agent family, backend, model, currency, and account generation with truthful
coverage, exact-generation tier annotations, an asterisk disclosure, and
bounded accessible drill-down. Other connections receive no protected values.

## Context and evidence

The prototype combines provider quota cards and multidimensional usage/cost in
one static summary. Those degrade independently and have different consumers.
DASH-015 now owns only provider-meter cards; this ticket owns the requested
ticket/model/agent/build accounting presentation. DASH-021 is a data-delivery
boundary, not a CSS hide, and subscription dollars are API-equivalent estimates
rather than billed spend.

## Scope

- Consume usage only through DASH-021's protected snapshot/subscription facade.
  Denied connections render its value-free `authentication_required` state and
  never query, subscribe to, cache, assign, emit, serialize, or receive usage,
  cost, generation, coverage, tier, or drill-down facts.
- Render DASH-030's `this_run` scope by default on Units. Accept an explicit
  typed member-set scope from DASH-023 for `this build`; never infer scope from
  labels, visible rows, URL text, or currently active workers.
- Present token and monetary totals plus bounded drill-down by ticket, provider,
  agent family, backend, exact model, currency, basis, and opaque account
  generation. Preserve coverage, revisions, retained interval, freshness,
  health, and unknown contributors.
- Display one exact `api_equivalent_estimate` total per compatible currency and
  reconcile it visibly to preserved contributors. Keep provider-reported
  estimates separate; never call either billed or actual spend.
- Mark subscription API-equivalent dollars with `*` and provide a keyboard/
  touch accessible information popover explaining the token-price lookup, the
  estimate basis, and why the user's flat subscription is not allocated.
- Join actual plan/tier annotations from DASH-020/013 only on exact known
  `(provider, backend, provider_account_generation)`. Unknown, mixed, and
  mismatched generations remain unjoined; a combined total never receives a
  synthetic cross-provider tier.
- Surface DASH-010 Remote Control and DASH-029 headless coverage separately so
  missing/partial source coverage cannot look like zero usage.
- On authorized mount/reconnect, fetch a bounded current snapshot and subscribe
  to daemon-owned changes. Coalesce rendering/announcements and isolate one
  scope/provider/query failure from healthy contributors.
- Reflow totals, disclosures, groups, and drill-down at 320/390/768/960/desktop
  and 200% zoom with semantic meters/tables/lists and 44px controls.

## Non-goals

- Render provider quota/rate/reset cards or the nonfinancial Aiur run summary;
  DASH-015 and DASH-022 own those surfaces.
- Ingest, persist, normalize, price, group, retain, or compact usage; fetch
  providers per browser; allocate subscription fees; or redesign Analytics.
- Combine unlike bases/currencies, guess a tier, expose account identity, or
  weaken DASH-021's locked state.

## Existing owner and reuse target

Add protected accounting presenters/components beside DASH-015 and DASH-022 in
DASH-003's Units composition. Reuse DASH-030 exact grouping, DASH-012 health
vocabulary through the provider adapters, and DASH-021 protected delivery.

## Contract and invariants

- Every rendered value names scope, source/basis, currency/generation,
  coverage, retained interval, health, and freshness where applicable.
- Unlike bases/currencies remain separate. Exact contributor sums reconcile to
  each displayed compatible-currency total. Unknown cost is not `$0.00`.
- Subscription estimates always carry `*` and an explanation. Tier appears
  only for an exact known generation; mixed/unknown/mismatch is explicit.
- Protected facts never enter a denied connection, including hidden DOM,
  assigns, client events, caches, logs, or generic APIs.
- Live updates are generation-keyed, bounded, focus-preserving, and coalesced.

## Refreshable implementation notes

- Refresh DASH-021/030 and provider-meter schemas at pickup. Build pure
  presenters against synthetic fixtures before wiring subscriptions.
- Keep pagination/drill-down server-bounded; large runs must not create an
  unbounded DOM or send full ledgers to the browser.
- Use machine-readable times and exact formatted decimal values. Coordinate
  shared summary/CSS ownership through declared serialization.

## Acceptance and verification

### Agent gate

- Presenter tests cover run/explicit-build scopes, every basis/currency/
  coverage/generation, exact tier join, unknown/mixed/mismatch, provider-source
  coverage, compatible-total reconciliation, loading/empty/stale/error, and
  live generation changes.
- Security integration proves denied mode invokes no protected provider and
  contains no token, dollar, group, account/auth-mode, plan/tier, quota, reset,
  coverage, freshness, LKG, or serialized hidden values.
- Browser/a11y tests cover keyboard/touch drill-down and popover, focus return,
  announcement coalescing, light/dark/reduced motion, 44px targets, 200% zoom,
  all breakpoints, and no clipping.

### At-merge gate

- Rebase all eight prerequisites and pass accounting, source-coverage,
  retention/compaction, provider-meter, auth/security, accessibility,
  performance, and full CI suites.

### Human/manual evidence

- From the Executor repository root, compare subscription, API-key, partial,
  stale, Remote-Control-inclusive, mixed-generation, and locked fixtures.
  Verify a mixed Codex/Claude total reconciles, remains asterisked, exposes only
  exact-generation tiers, and leaks no protected value in denied page source or
  events.

## Failure, security, migration, and accessibility cases

- A degraded scope/provider preserves safe qualified LKG or a named unknown;
  it never resets usage/cost to zero or borrows the current account's tier.
- Protected values never enter unauthenticated HTML, assigns, events, caches,
  logs, prompts, bug reports, or generic APIs. Evidence uses synthetic values.
- No storage migration; prerequisite schemas own compatibility. All metrics,
  disclosures, groups, states, and actions are named and non-color-dependent.

## Surfaces

- Reads: DASH-030 grouped usage, DASH-010/029 source coverage, DASH-013/020
  exact-generation meter facts, DASH-025 retained coverage, DASH-021 protected
  delivery, and explicit run/build scope.
- Writes: protected accounting presenters/components, bounded drill-down and
  popover, authorized subscriptions, responsive CSS, and tests.
- Contracts: authenticated usage/cost summary, exact tier composition, estimate
  disclosure, contributor reconciliation, and live scope behavior.
- Safety: financial-data nonleakage and generation-safe updates.

## Sibling boundaries and open gates

DASH-015 owns provider-meter cards and DASH-022 owns nonfinancial run status.
DASH-023 later integrates selected Build Order membership on top of this
summary; this ticket ships without any Build Order scope. Provider authority gates remain owned by DASH-013/019 and
flow transitively through their dependent source paths.
