# DASH-011 — Project cost and usage groups

**Kind:** executable

**Provenance:** planned in plan v1 after cost-policy decisions and adversarial review

**Complexity:** 4 — Versioned exact pricing and multi-dimensional retained-coverage queries

**Risk:** high

**Depends on:** DASH-024

**Serializes with:** none

**External gate:** `GATE-OCC-PREDECESSOR-BASELINE` — resolve before dispatch

**Requirements:** DREQ-011

**Researched at:** `9849f32963c2a65367bce565b3f5ede3777c218f`

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Aiur returns exact-arithmetic, scope-labelled token and dollar totals by
run/build, ticket, agent family, backend, resolved model, currency, and opaque
provider-account generation, plus a compatible-currency API-equivalent total
across providers and account generations. Provider-reported and versioned
API-equivalent bases remain distinct, and every token total and price follows
the pinned DASH-008 provider/source relationship revision, with explicit
retained coverage and unknowns.

## Context and evidence

The user requires spend and tokens per ticket, agent type, model, and total build. Subscription use is not a per-ticket invoice: the accepted policy is a versioned API-equivalent estimate with an asterisk/explanation and the actual account tier shown separately. A selected Build Order includes all retained usage attributable to its current GitHub member tickets, including usage recorded before membership; there is no joined-at cutoff. Provider-reported request cost and estimates cannot be silently added into one unlabeled spend value.

## Scope

- Define exactly two v1 monetary bases:
  - `provider_reported_estimate` when the provider's structured request event reports an estimated request cost;
  - `api_equivalent_estimate` derived from observed tokens, exact resolved model, token dimension, and a versioned/effective-dated price table.
  Unknown basis/model/pricing/currency remains unknown. Do not add fixed-subscription allocation or organization-billing reconciliation in v1.
- Store/query currency in integer micros or exact decimal. Price input, arithmetic, and output never pass through binary float.
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
- Expose a query over an explicit typed ticket set and/or run set returning tokens and monetary totals by basis, plus groups by provider, ticket, agent family, backend, resolved model, auth mode, opaque `provider_account_generation`, currency, and run. Include occurrence-price bucket/revision coverage, unknown contributors, pricing/model coverage, ledger health, and earliest/latest retained coverage.
- Define Build Order scope as the caller-supplied current GitHub member set. Include every retained observation for those identities, including pre-membership usage; exclude unrelated tickets and do not infer membership from labels/prose.
- Preserve provider/account generation buckets for attribution and tier
  correlation, then expose one exact `api_equivalent_estimate` roll-up per
  compatible currency across those buckets. The roll-up must reconcile to its
  provider, account-generation, ticket, agent-family, backend and model
  contributors and must retain partial/pricing coverage. Never mix currencies
  or `provider_reported_estimate` with `api_equivalent_estimate`; provider-
  reported values stay separately labelled.
- For subscription auth, return API-equivalent estimate metadata requiring `*`, information-popover copy key, and a generation-qualified tier join key of `(provider, backend, provider_account_generation)`. This ticket does not ingest or join meter data. DASH-015 may attach actual tier only from DASH-020/013 facts with that exact known generation; missing, unknown, or mixed generations require an unjoined `unknown`/`mixed` tier state. It must not be named billed or actual spend. A multi-generation roll-up carries contributor tier states, not one synthetic tier.
- Provide deterministic empty, partial, stale/corrupt-ledger, unknown-price,
  unknown-model, unknown/contradictory token-relationship, mixed-currency, and
  partial-retention results.

## Non-goals

- Ingest/persist usage, fetch provider meters or organization invoices, allocate a flat subscription fee, scrape live pricing pages, render UI, or write totals to GitHub.
- Join plan/tier meter facts, infer an account match from provider/backend alone,
  or apply one current tier to historical usage spanning account generations.
- Claim OpenAI/Anthropic organization billing data is attributable to an Aiur ticket without a separate reviewed correlation source.
- Reprice historical observations with today's model price or turn unknown cost into `$0.00`.

## Existing owner and reuse target

Build a pure pricing/grouping layer over DASH-024's aggregate/query behavior,
resolve its pinned revision IDs through DASH-008's immutable versioned
relationship registry, and use a versioned checked-in/configured price table
with exact-money helpers. Keep all financial policy outside LiveView.

## Contract and invariants

- Every monetary result carries currency, basis, scope, pricing revision/effective date where applicable, model/token coverage, and retained coverage.
- Unlike bases and currencies are never arithmetically combined. Provider and
  account generation remain exact contributor dimensions, while compatible-
  currency API-equivalent contributors are deliberately summed into the
  comparable run/build estimate. Unknown contributors remain in token totals
  and make monetary coverage partial/unknown.
- `provider_reported_estimate` is accepted only from a DASH-008/010 source that declares structured estimated request cost; it is not inferred from a subscription fee.
- Current-build membership is caller-supplied current GitHub identity. The query includes all retained observations for each current member, with no membership-time cutoff.
- Historical pricing joins require exact provider, resolved model, token
  dimension, token-relationship revision, currency, and UTC occurrence-price
  interval. Tier correlation is not a pricing join and is exposed only as an
  exact opaque-generation key for DASH-015; this projection never reads meter
  snapshots.
- A retained relationship ID must resolve to exactly one immutable DASH-008
  registry entry. Missing, ambiguous, or replaced semantics remain unknown and
  cannot fall forward to the newest registry revision.
- Canonical token reconciliation and billable price reconciliation are related
  but distinct: additive dimensions count and price separately; subset
  dimensions count through the parent but price the child and parent remainder
  separately; provider-total authority cannot conceal a dimension mismatch.
- Group sums reconcile exactly to their matching basis/scope/currency/account-generation buckets, and every compatible-currency API-equivalent roll-up reconciles exactly to all of its provider/generation/ticket/agent/backend/model contributors; unrelated identities cannot enter through bare-number collisions.

## Refreshable implementation notes

- Seed price fixtures from an explicitly reviewed revision at pickup; record
  source, currency, and inclusive UTC effective dates, validate non-overlapping
  intervals, but perform no runtime web fetch.
- Keep estimates reproducible by storing the revision table in source/config and selecting by the retained UTC occurrence-price bucket. Add a coverage reason when an observation predates known pricing or no exact currency series exists.
- Keep the DASH-008 token-relationship revision beside every pricing input and
  contributor. Never infer a historical relationship from the provider's
  current schema or price table.
- Reconcile #132 as covered/superseded for per-ticket estimate semantics; its TUI-specific rendering remains outside this ticket.

## Acceptance and verification

### Agent gate

- Exact-arithmetic/property tests cover each basis, model/token price
  dimension, UTC effective-date boundaries, price-interval
  non-overlap/ambiguity validation, unknown model/auth/price, mixed
  bases/currencies/account generations, completed and unrelated tickets, and
  bucket/roll-up reconciliation. Dedicated fixtures prove Claude base input +
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
- Join-safety tests prove pricing never crosses provider or currency, grouped
  contributor output never merges known/unknown or different account
  generations, the compatible API-equivalent roll-up sums only same-currency
  contributors, and the emitted tier key cannot correlate an unknown/mixed
  generation or authorize a provider/backend-only join.
- Scope tests prove current-member pre-membership usage is included, removed/nonmember usage is excluded, bare issue numbers cannot collide, and run versus build labels remain distinct.
- Ledger failure/retention tests cover empty, partial, corrupt/unavailable health and earliest/latest coverage without converting gaps to zero.

### At-merge gate

- Rebase on DASH-024 and the resolved configured integration target; run aggregate/query, pricing, exact-money, membership identity, security, regression, and full CI suites. Review price fixtures and policy copy as code/data changes.

### Human/manual evidence

- Executor reviews a synthetic mixed Codex/Claude subscription example showing
  one asterisked compatible-currency API-equivalent run/build estimate that
  reconciles to both provider/generation groups, separately labelled provider-
  reported estimates, and exact-generation-only tier annotations. Confirm
  unlike bases/currencies are not summed and generations are not tier-
  correlated.

## Failure, security, migration, and accessibility cases

- Missing pricing/model/auth or degraded ledger produces partial/unknown with a reason; it never fails open to a monetary zero.
- Treat grouped financial/Executor facts as sensitive. Do not log query rows, account identity, credentials, or raw provider events.
- Version price tables and output schema. Replay/query migration preserves
  historical basis/revision, token-relationship revision, currency,
  occurrence-price partition, and opaque account-generation semantics.
- No direct UI; all basis, scope, coverage, and unknown reason fields have human-readable labels for DASH-015.

## Surfaces

- Reads: DASH-024 aggregate/query behavior with retained occurrence-price,
  token-relationship, currency, and opaque account-generation partitions;
  DASH-008's immutable provider/source/source-version token-relationship
  registry behind each pinned revision ID; versioned price table; explicit
  typed run/ticket membership sets. It does not read raw usage files or
  provider meters.
- Writes: cost/usage grouping projection and query API, pricing revisions/fixtures, tests.
- Contracts: relationship-aware exact effective-date/currency pricing and
  token/provider-total reconciliation, generation-qualified tier join key,
  compatible-currency API-equivalent roll-up with preserved contributors,
  exact grouped summary, current-build retained-membership semantics.

## Sibling boundaries and open gates

DASH-009 owns raw append/replay and DASH-024 owns the aggregate query consumed
here. The transitive DASH-011 → DASH-024 → DASH-009 → DASH-008 dependency chain
orders the immutable relationship registry before pricing, so a redundant
direct edge is unnecessary; this ticket reads the public DASH-008 registry
contract, never raw envelopes. DASH-010 supplies required Remote Control
observations but does not block developing this projection against fixtures.
DASH-012 owns the meter contract, and DASH-020/013 own actual Codex/Claude
account facts; DASH-011 deliberately does not depend on or join them.
DASH-015 is the sole composition owner that may join usage groups to tier facts,
and only by provider, backend, and the exact known opaque generation. It must
keep bases/currencies separate, preserve generation contributor groups, and
apply the subscription estimate disclosure exactly to the compatible API-
equivalent total and its constituents.
