# DASH-011 — Resolve exact usage pricing

**Kind:** executable

**Provenance:** planned in plan v1 after cost-policy decisions and adversarial review

**Complexity:** 3 — Versioned exact pricing and relationship-aware token reconciliation

**Risk:** high

**Depends on:** DASH-008

**Serializes with:** none

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-011

**Researched at:** `9849f32963c2a65367bce565b3f5ede3777c218f`

**Suggested labels:** `complexity:3`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Aiur resolves normalized usage into exact, reproducible token reconciliation
and monetary slices under immutable occurrence-time price and DASH-008 token-
relationship revisions. Provider-reported and API-equivalent bases remain
distinct, and unknown or contradictory inputs fail closed without inventing a
price or token total.

## Context and evidence

The user requires spend and tokens per ticket, agent type, model, and total
build. Subscription use is not a per-ticket invoice, so the accepted monetary
policy is a reproducible API-equivalent estimate. Pricing policy and
multidimensional grouping are separate review boundaries: this ticket owns the
former, while DASH-030 owns run/build/ticket grouping and reconciliation.

## Scope

- Define exactly two v1 monetary bases:
  - `provider_reported_estimate` when the provider's structured request event reports an estimated request cost;
  - `api_equivalent_estimate` derived from observed tokens, exact resolved model, token dimension, and a versioned/effective-dated price table.
  Unknown basis/model/pricing/currency remains unknown. Do not add fixed-subscription allocation or organization-billing reconciliation in v1.
- Store currency in integer micros or exact decimal. Price input, arithmetic,
  and output never pass through binary float.
- Define price applicability at the exact DASH-008/DASH-009 UTC
  `pricing_effective_date` bucket. Within a `(provider, resolved_model,
  token_dimension, currency)` price series, every revision has an inclusive UTC
  `effective_date` and an exclusive next-revision date; intervals cannot overlap
  or leave an ambiguous winner. Select the unique interval containing the
  observation bucket. Never select by ingestion, compaction, or query time, and
  never fall back across currency or provider.
- Consume the pinned DASH-008 token-relationship revision as a required pricing
  and reconciliation dimension. Resolve that exact ID through DASH-008's
  immutable registry; never infer semantics from the provider, current source
  version, or current price table when the retained revision is absent. Price
  additive dimensions independently and add their exact costs. For a
  `subset_of` relationship, price the child at its own rate and only the parent
  remainder at the parent rate while counting the parent once in canonical
  token totals. Price only the one valid observed member of a mutually
  exclusive group. Thus Claude base input, cache creation, and cache read are
  three separately priced additive dimensions, while a supported Codex
  cached-input subset is removed from its parent input slice before the two
  price components are summed. Preserve output/reasoning distinctions under
  the same contract.
- Treat provider-total authority as token-total authority, not a substitute for
  billable dimensions. Preserve and reconcile the provider total, but do not
  use it to fabricate a dimension-level API-equivalent estimate. Unknown,
  missing, contradictory, or arithmetically impossible relationships produce
  explicit partial/unknown API-equivalent coverage, never a guessed estimate
  or `$0.00`. Existing effective-date and relationship revisions are immutable
  after acceptance; a correction is a new explicitly versioned revision with
  a migration/recalculation disposition, never silent historical repricing.
- Emit an immutable per-observation or per-preserved aggregate-slice pricing
  result containing canonical token reconciliation, provider-reported estimate
  when present, API-equivalent estimate when fully supported, currency/basis,
  provider/model/dimension, occurrence-price revision, relationship revision,
  opaque account generation, exact-generation tier-join key when possible,
  and explicit coverage/reason fields. DASH-030 groups these slices.
- For subscription auth, attach metadata requiring `*` and an information-
  popover copy key. It must not be named billed or actual spend. This ticket
  does not read meter facts or attach a tier.
- Provide deterministic known, partial, unknown-price, unknown-model, unknown/
  contradictory relationship, invalid arithmetic, and unsupported-currency
  results without consulting current time, browser state, or provider I/O.

## Non-goals

- Ingest/persist/aggregate/query usage, discover run/build membership, fetch
  provider meters or organization invoices, allocate a flat subscription fee,
  scrape live pricing pages, render UI, or write totals to GitHub.
- Join plan/tier meter facts, infer an account match from provider/backend alone,
  or apply one current tier to historical usage spanning account generations.
- Claim OpenAI/Anthropic organization billing data is attributable to an Aiur ticket without a separate reviewed correlation source.
- Reprice historical observations with today's model price or turn unknown cost into `$0.00`.

## Existing owner and reuse target

Build a pure pricing/token-reconciliation library over DASH-008's immutable
relationship registry and a versioned checked-in/configured price table with
exact-money helpers. DASH-030 invokes it over DASH-024's preserved aggregate
slices. Keep all financial policy outside LiveView.

## Contract and invariants

- Every result carries currency, basis, pricing revision/effective date where
  applicable, token-relationship revision, provider/model/dimension, opaque
  account generation, and token/pricing coverage.
- Unlike bases and currencies are never arithmetically combined. This ticket
  prices one preserved slice; DASH-030 alone produces contributor groups and
  compatible-currency roll-ups.
- `provider_reported_estimate` is accepted only from a DASH-008/010 source that declares structured estimated request cost; it is not inferred from a subscription fee.
- Historical pricing joins require exact provider, resolved model, token
  dimension, token-relationship revision, currency, and UTC occurrence-price
  interval. Tier correlation is not a pricing join and is exposed only as an
  exact opaque-generation key for DASH-031; this resolver never reads meter
  snapshots.
- A retained relationship ID must resolve to exactly one immutable DASH-008
  registry entry. Missing, ambiguous, or replaced semantics remain unknown and
  cannot fall forward to the newest registry revision.
- Canonical token reconciliation and billable price reconciliation are related
  but distinct: additive dimensions count and price separately; subset
  dimensions count through the parent but price the child and parent remainder
  separately; provider-total authority cannot conceal a dimension mismatch.
- Each resolved slice reconciles its canonical token dimensions, provider total,
  and priced components exactly. Group/roll-up reconciliation is DASH-030's
  contract.

## Refreshable implementation notes

- Seed price fixtures from an explicitly reviewed revision at pickup; record
  source, currency, and inclusive UTC effective dates, validate non-overlapping
  intervals, but perform no runtime web fetch.
- Keep estimates reproducible by storing the revision table in source/config and selecting by the retained UTC occurrence-price bucket. Add a coverage reason when an observation predates known pricing or no exact currency series exists.
- Keep the DASH-008 token-relationship revision beside every pricing input and
  contributor. Never infer a historical relationship from the provider's
  current schema or price table.
- Reconcile #132 as covered/superseded for price semantics; its grouped query
  and TUI-specific rendering remain outside this ticket.

## Acceptance and verification

### Agent gate

- Exact-arithmetic/property tests cover each basis, model/token price
  dimension, UTC effective-date boundaries, price-interval non-overlap/
  ambiguity validation, unknown model/auth/price, bases, currencies, and
  account generations. Dedicated fixtures prove Claude base input +
  cache creation + cache read are additive in both token and separately priced
  cost reconciliation, while Codex cached input is a priced subset whose count
  is not added again to parent input.
- Relationship tests cover valid mutually exclusive alternatives,
  contradictory alternatives, provider-total authority with matching and
  mismatching dimensions, absent provider total with safe derivation, and
  missing/ambiguous/replaced registry revisions. Contradictory/unknown fixtures
  retain raw token and provider-total evidence but emit no API-equivalent
  estimate, and an old pinned ID never resolves through current provider/source
  defaults.
- Join-safety tests prove pricing never crosses provider/currency/model/
  relationship revision and the emitted tier key cannot correlate an unknown
  generation or authorize a provider/backend-only join.

### At-merge gate

- Rebase on DASH-008 and the resolved configured integration target; run
  relationship, pricing, exact-money, security, regression, and full CI suites.
  Review price fixtures and policy copy as code/data changes.

### Human/manual evidence

- Executor reviews synthetic Claude-additive and Codex-subset slices with
  occurrence-time pricing, exact provider-reported/API-equivalent separation,
  asterisk metadata, and unknown/mismatched revisions. DASH-030/031 own grouped
  totals and presentation proof.

## Failure, security, migration, and accessibility cases

- Missing pricing/model/auth/relationship data produces partial/unknown with a
  reason; it never fails open to a monetary zero.
- Treat pricing inputs/results as sensitive. Do not log account identity,
  credentials, or raw provider events.
- Version price tables and output schema. Downstream replay/query migration preserves
  historical basis/revision, token-relationship revision, currency,
  occurrence-price partition, and opaque account-generation semantics.
- No direct UI; all basis, coverage, and unknown reason fields have human-
  readable labels for DASH-030/031.

## Surfaces

- Reads: DASH-008 normalized pricing inputs and immutable provider/source/
  source-version relationship registry; versioned price table. It does not
  read raw usage files, aggregate stores, scopes, or provider meters.
- Writes: exact pricing/token-reconciliation resolver, immutable price
  revisions/fixtures, and tests.
- Contracts: relationship-aware exact effective-date/currency pricing and
  token/provider-total reconciliation, and generation-qualified tier join key.

## Sibling boundaries and open gates

DASH-008 owns the immutable relationship registry consumed here. DASH-009/024
own persistence and raw aggregate queries; DASH-030 combines DASH-024 slices
with this resolver into scoped groups. DASH-010/029 supply observations but do
not block developing pricing against fixtures.
DASH-012 owns the meter contract, and DASH-020/013 own actual Codex/Claude
account facts; DASH-011 deliberately does not depend on or join them.
DASH-031 is the sole composition owner that may join usage groups to tier facts,
and only by provider, backend, and the exact known opaque generation. It must
keep bases/currencies separate, preserve generation contributor groups, and
apply the subscription estimate disclosure exactly to the DASH-030 compatible
API-equivalent total and its constituents.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-011`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
