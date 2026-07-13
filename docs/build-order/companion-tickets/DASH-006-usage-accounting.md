# DASH-006 — Project cost and usage aggregations

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Versioned financial semantics and multi-dimensional query projection

**Risk:** high

**Depends on:** DASH-005

**Requirements:** DREQ-006

**Researched at:** 3d67b7be722eb649f28088fc8d609dd7b75254c7

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Aiur computes exact, basis-labelled token/cost totals and coverage by selected build/run, ticket, agent family, backend, and resolved model without rewriting history or treating unknown cost as zero.

## Context and evidence

The operator explicitly needs spend per agent type, per ticket, and total build, plus tokens per ticket, model, and total build. Subscription, API-key, provider-reported, actual, estimated, fixed, allocated, and unknown values cannot safely collapse into one unlabeled dollar figure.

## Scope

- Define cost bases `provider_reported`, `metered_actual`, `api_equivalent_estimate`, `subscription_fixed`, `allocated`, and `unknown` using integer USD micros/exact decimal.
- Apply versioned effective-dated prices by exact resolved model and token dimension; retain history under its original pricing revision.
- Expose grouped summary over explicit ticket/run sets: totals and by agent family, backend, model, and ticket, with basis/coverage/store health and unrelated-ticket exclusion.
- Define current-build membership window behavior behind the recorded operator gate and distinguish `this build` from `this run`.
- Handle mixed/unknown auth/model/cost and configured subscription fee without silently allocating it.

## Non-goals

- Persist raw events, fetch provider quota, render cards, scrape pricing/provider pages at runtime, or write totals to GitHub.
- Infer actual billed spend from token estimates.

## Existing owner and reuse target

Build a pure/durable projection/query over DASH-005 observations, reusing exact-money and migration conventions where present. Do not add financial policy to LiveView.

## Contract and invariants

- Every monetary total carries basis, pricing revision/coverage, currency, and scope.
- Unknown contributors make coverage partial/unknown, never `$0.00`. Historical totals do not change when prices update.
- Caller supplies canonical ticket/run identity sets; query does not infer Build Order membership from prose/labels.
- Subscription fixed fees and any allocation remain separately labelled from usage-based estimates/actuals.

## Refreshable implementation notes

- Resolve the flat-subscription and membership-time questions before dispatch or implement the documented recommended defaults.
- Use pricing fixtures and effective dates; no live price fetch in tests/runtime.

## Acceptance and verification

### Agent gate

- Tests cover each basis, mixed bases, unknown model/auth, cached/reasoning dimensions, price revisions, fixed fee, optional allocation, completed/unrelated tickets, build vs run scopes, empty/partial/corrupt store.
- Exact arithmetic tests prove no float drift.

### At-merge gate

- Accounting/migration/query/security and full current-base CI pass.

### Human/manual evidence

- Operator approves subscription cost display and Build Order membership-window semantics before final UI acceptance.

## Failure, security, migration, and accessibility cases

- Treat spend as sensitive authenticated data; never log account identity.
- Version all projection/pricing migrations and retain replayability.
- No direct UI; output includes accessible explanatory labels.

## Surfaces

- Reads: durable UsageObservations; versioned pricing/config; explicit ticket/run identity sets.
- Writes: cost/coverage aggregation projection and query API.
- Contracts: UsageSummary and cost-basis/coverage semantics.

## Sibling boundaries and open gates

DASH-005 owns observations. DASH-008 consumes summaries. GitHub remains Build Order membership truth; this ticket receives IDs rather than duplicating them.

