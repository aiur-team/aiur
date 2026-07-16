---
title: "feat: Resolve exact usage pricing"
type: feat
status: active
date: 2026-07-15
origin: docs/brainstorms/2026-07-12-build-order-requirements.md
---

# feat: Resolve exact usage pricing

## Summary

Add a pure occurrence-time price table and relationship-aware pricing resolver over the landed `Aiur.UsageEnvelope` contract. The resolver will preserve provider estimates separately, derive API-equivalent components with exact decimal arithmetic, and emit explicit unknown coverage instead of guessing.

---

## Problem Frame

Aiur now preserves exact raw usage measurements and immutable token-relationship revisions, but it has no reproducible policy for converting those observations into monetary slices. DASH-011 must supply that policy without taking over persistence, grouping, account meters, or presentation.

---

## Assumptions

*This plan was authored without synchronous user confirmation. The items below are agent inferences that fill gaps in the input and should remain visible during implementation and review.*

- Checked-in provider prices represent standard, global, direct-provider, non-batch API-equivalent rates in USD; modifiers not represented by `UsageEnvelope` remain unsupported rather than inferred.
- A provider price first reviewed on 2026-07-15 becomes applicable on that UTC date. Earlier observations remain unknown rather than being silently back-priced.
- Price keys use exact provider-reported model IDs. Requested-model aliases are not normalized into resolved models.

---

## Requirements

- **DREQ-011.1:** Resolve a unique immutable price revision by exact provider, resolved model, token dimension, relationship revision, currency, and UTC occurrence-price interval.
- **DREQ-011.2:** Keep provider-reported and API-equivalent estimates as distinct bases and currencies, using exact decimal arithmetic only.
- **DREQ-011.3:** Price additive dimensions independently, subset children plus parent remainder, and one valid mutually exclusive member without double counting canonical tokens.
- **DREQ-011.4:** Preserve canonical token/provider-total reconciliation and raw evidence while returning explicit partial or unknown coverage for missing, contradictory, unsupported, or arithmetically impossible inputs.
- **DREQ-011.5:** Emit occurrence price/relationship revisions, provider/model/dimension contributors, opaque account generation, generation-qualified tier key, and subscription-estimate disclosure metadata without consulting meters or provider I/O.

---

## Scope Boundaries

- No usage ingestion, ledger, aggregate query, compaction, provider fetch, supervision child, LiveView, or UI changes.
- No fixed-subscription allocation, billed/actual-spend claim, organization billing reconciliation, or runtime pricing scrape.
- No run/build/ticket grouping, compatible-currency roll-up, meter/tier lookup, or account inference; DASH-030/031 own those responsibilities.
- No model alias normalization or fallback across provider, model, relationship revision, currency, or time.

---

## Context & Research

### Relevant Code and Patterns

- `src/lib/aiur/usage_envelope.ex` supplies occurrence-price date, resolved model, auth mode, opaque generation, raw token dimensions, and exact provider cost.
- `src/lib/aiur/usage_envelope/relationship_registry.ex` owns immutable relationship lookup and canonical token/provider-total reconciliation.
- `src/lib/aiur/usage_envelope/exact_money.ex` establishes the no-float boundary and exact `Decimal` serialization conventions.
- `src/test/aiur/usage_envelope/relationship_registry_test.exs` supplies additive, subset, mutually exclusive, provider-total, missing-revision, and property-test patterns.

### Institutional Learnings

- `CONTRIBUTING.md` requires boundary validation, structured errors, adjacent public specs, pure utility tests without mocks, strict lint/spec checks, and Dialyzer.

### External References

- OpenAI standard model rates reviewed 2026-07-15: https://developers.openai.com/api/docs/pricing
- Anthropic model and prompt-cache rates reviewed 2026-07-15: https://platform.claude.com/docs/en/about-claude/pricing

---

## Key Technical Decisions

- Represent table rates as string-valued major-currency amounts per integer token unit, decoded to `Decimal` during table validation; reject floats at the boundary.
- Store each occurrence revision with an inclusive UTC effective date and derive its exclusive bound from the next revision in the exact series. Duplicate effective dates or conflicting immutable revisions invalidate the catalog.
- Ask DASH-008 to resolve and reconcile the exact pinned relationship revision first. API-equivalent pricing proceeds only when relationship and dimension reconciliation are fully supported; an authoritative provider total never fills missing billable dimensions.
- Emit exact component slices before summing them so downstream DASH-030 can reconcile provider/model/dimension contributors without reverse-engineering a total.
- Treat `:chatgpt` as the currently explicit subscription auth mode and attach an asterisk plus copy key only to its API-equivalent estimate. `:unknown` auth remains unsupported.

---

## Implementation Units

### U1. Versioned exact price table

**Goal:** Validate immutable price revisions and resolve the unique occurrence-time price for an exact pricing join.

**Requirements:** DREQ-011.1, DREQ-011.2, DREQ-011.4

**Dependencies:** Landed DASH-008 exact-money conventions.

**Files:**

- Create: `src/lib/aiur/usage/price_table.ex`
- Create: `src/lib/aiur/usage/price_table/data.ex`
- Test: `src/test/aiur/usage/price_table_test.exs`

**Approach:**

- Keep reviewed provider rates in source as string values with currency, token unit, exact model/dimension/relationship keys, revision, effective date, source URL, and review date.
- Normalize and validate catalogs before lookup. Series are exact-keyed and effective dates are unique and ordered; lookup derives the exclusive next-revision bound.
- Return structured no-match reasons that distinguish unknown model, unsupported currency, missing relationship-series price, and observation before the first known revision.

**Execution note:** Implement catalog boundary and interval tests first because ambiguous historical selection is the highest-risk failure mode.

**Patterns to follow:**

- Exact scalar/float rejection in `src/lib/aiur/usage_envelope/exact_money.ex`.
- Immutable conflict detection in `src/lib/aiur/usage_envelope/relationship_registry.ex`.

**Test scenarios:**

- Happy path: each seeded provider/model/token dimension resolves to a `Decimal` rate and exact provenance on the inclusive effective date.
- Edge case: the day before and day of a second revision select the old and new revisions respectively; lookup is independent of current/ingestion time.
- Error path: duplicate effective dates, conflicting revision IDs, floats, invalid currencies, invalid units, and malformed provenance reject catalog construction.
- Error path: exact lookup never crosses provider, model, relationship revision, token dimension, or currency and reports pre-history separately from an unknown series.
- Property: for generated ordered revisions and dates, at most one interval wins and boundary selection is deterministic.

**Verification:**

- A validated catalog has one unambiguous winner or a structured unknown reason for every exact lookup.

### U2. Relationship-aware pricing result

**Goal:** Convert one usage envelope into immutable canonical token reconciliation plus separate exact provider/API-equivalent estimates and contributor slices.

**Requirements:** DREQ-011.2, DREQ-011.3, DREQ-011.4, DREQ-011.5

**Dependencies:** U1 and landed DASH-008 relationship registry.

**Files:**

- Create: `src/lib/aiur/usage/pricing.ex`
- Create: `src/lib/aiur/usage/pricing/components.ex`
- Test: `src/test/aiur/usage/pricing_test.exs`
- Test: `src/test/aiur/usage/pricing_property_test.exs`

**Approach:**

- Resolve and reconcile the envelope's exact pinned relationship revision without any provider/source/version fallback.
- Build billable components directly from raw dimensions: additive values contribute whole; every subset child is priced separately while direct child counts are removed from the parent slice; mutually exclusive groups contribute only their one valid observed member.
- Reject missing price-affecting dimensions, overlapping subset children, contradictory alternatives, invalid parent remainder, unknown relationship/auth/model/currency/date, partial updates, and provider-total discrepancies from API-equivalent estimation while retaining evidence and reasons.
- Preserve a non-null provider-reported estimate independently from API pricing. Sum API components only when every required component has one exact price and the relationship reconciliation is full.
- Emit exact amount strings/decimals, contributor rates and token counts, price and relationship revisions, account generation, optional exact generation tier key, and subscription disclosure metadata.

**Execution note:** Add synthetic Claude-additive and Codex-subset tests before implementing the component fold.

**Patterns to follow:**

- Reconciliation status and reason semantics in `src/lib/aiur/usage_envelope/relationship_registry.ex`.
- Envelope and exact provider-cost fixtures in `src/test/aiur/usage_envelope_test.exs` and `src/test/aiur/usage_envelope/relationship_registry_test.exs`.

**Test scenarios:**

- Happy path: Claude base input, cache creation, cache read, output, and reasoning reconcile canonically and price as separate exact additive/subset components.
- Happy path: Codex cached input and reasoning are priced separately while removed from input/output parent slices; canonical totals count each parent once.
- Happy path: provider-reported estimate is preserved beside, not added to or substituted for, an API-equivalent estimate.
- Edge case: exactly one mutually exclusive alternative prices; multiple contradictory alternatives emit no API estimate.
- Edge case: authoritative provider total with matching dimensions prices; mismatching dimensions retain the total/evidence but emit no API estimate; absent provider total safely derives from complete dimensions.
- Error path: unknown model/auth/currency/price/date, partial update, missing/invalid relationship revision, missing dimension, overlapping subset children, negative parent remainder, and unsupported currency all fail closed without a monetary zero.
- Join safety: tier key exists only for exact known provider/backend/generation; unknown generation cannot correlate, and provider/backend alone never produces a key.
- Disclosure: subscription API-equivalent estimates carry `*` and the information-copy key and are never labeled billed or actual spend.
- Property: generated non-negative parent/child counts never double count tokens, component costs sum exactly, and unlike bases/currencies are never combined.

**Verification:**

- Every supported observation produces exactly reproducible token and money slices; unsupported evidence remains explicit and cannot become a guessed total or `$0.00`.

---

## System-Wide Impact

- **Interaction graph:** Pure call path only: DASH-024/030 will pass preserved envelopes or slices into DASH-011; no callbacks, processes, storage, or broadcasts fire.
- **Error propagation:** Catalog construction returns structured validation errors; per-observation unsupported inputs return a successful result with explicit unknown/partial coverage reasons.
- **State lifecycle risks:** None at runtime; immutable source revisions and pickup-time provenance make historical replay deterministic.
- **API surface parity:** Provider-reported and API-equivalent bases remain separate public result fields; no incumbent token-accounting API changes.
- **Integration coverage:** Tests use real `UsageEnvelope` and `RelationshipRegistry` values end to end without mocks.
- **Unchanged invariants:** DASH-008 remains the only relationship authority; DASH-030 remains the only grouped roll-up owner; DASH-031 remains the only tier-composition/UI owner.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Current provider pages include modifiers not represented by `UsageEnvelope` | Seed only the documented standard/global/non-batch policy and fail closed for unsupported join inputs; record source and review date. |
| A provider-total value could conceal incomplete billable dimensions | Require full dimensional relationship reconciliation before API pricing; preserve provider total only as token evidence. |
| Multiple subset children could exceed their parent together | Validate aggregate direct-child subtraction before pricing any component. |
| Future price corrections could silently rewrite history | Treat existing revision IDs as immutable; corrections add a new effective-dated revision. |

---

## Documentation / Operational Notes

- Price source/review metadata ships with the table; there is no runtime refresh job.
- Later source updates must add immutable revisions and a documented replay/migration disposition rather than editing historical entries.

---

## Sources & References

- **Origin document:** `docs/brainstorms/2026-07-12-build-order-requirements.md` (DREQ-011)
- Accounting policy: `docs/build-order/04-usage-accounting.md`
- Technical decision: `docs/build-order/05-technical-decisions.md` (DEC-009)
- Execution amendment: `docs/build-order/11-execution-amendment.md` (DEC-015)
- Implementation pointers: `docs/build-order/08-implementation-pointers.md` (DASH-011)
- Dependency: PR #1114 / commit `e4955d8051669dcc05ccc6b7628890d364ae834a`
- Issue: #1117
