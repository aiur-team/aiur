# DASH-011 — Project cost and usage groups

**Kind:** executable

**Provenance:** planned in plan v1 after cost-policy decisions and adversarial review

**Complexity:** 4 — Versioned exact pricing and multi-dimensional retained-coverage queries

**Risk:** high

**Depends on:** DASH-009

**Serializes with:** usage query, pricing revision, and accounting projection changes

**External gate:** `GATE-OCC-PREDECESSOR-BASELINE` — resolve before dispatch

**Requirements:** DREQ-011

**Researched at:** `1e0cfba31c0e6cc4fea14a25e8b4344ef1d6d67d`

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Aiur returns exact-arithmetic, scope-labelled token and dollar totals by
run/build, ticket, agent family, backend, resolved model, currency, and opaque
provider-account generation using separately comparable provider-reported or
versioned API-equivalent estimate bases, with explicit retained coverage and
unknowns.

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
- Preserve cached input, cache-creation input, and output/reasoning pricing distinctions without double counting token subsets. Existing effective-date rows are immutable after acceptance; a correction is a new explicitly versioned table revision with a migration/recalculation disposition, never silent historical repricing.
- Expose a query over an explicit typed ticket set and/or run set returning tokens and monetary totals by basis, plus groups by provider, ticket, agent family, backend, resolved model, auth mode, opaque `provider_account_generation`, currency, and run. Include occurrence-price bucket/revision coverage, unknown contributors, pricing/model coverage, ledger health, and earliest/latest retained coverage.
- Define Build Order scope as the caller-supplied current GitHub member set. Include every retained observation for those identities, including pre-membership usage; exclude unrelated tickets and do not infer membership from labels/prose.
- For subscription auth, return API-equivalent estimate metadata requiring `*`, information-popover copy key, and a generation-qualified tier join key of `(provider, backend, provider_account_generation)`. This ticket does not ingest or join meter data. DASH-015 may attach actual tier only from DASH-012/013 facts with that exact known generation; missing, unknown, or mixed generations require an unjoined `unknown`/`mixed` tier state. It must not be named billed or actual spend. For mixed bases, currencies, or account generations, return separate buckets; never produce a combined dollar total across unlike identities.
- Provide deterministic empty, partial, stale/corrupt-ledger, unknown-price, unknown-model, mixed-currency, and partial-retention results.

## Non-goals

- Ingest/persist usage, fetch provider meters or organization invoices, allocate a flat subscription fee, scrape live pricing pages, render UI, or write totals to GitHub.
- Join plan/tier meter facts, infer an account match from provider/backend alone,
  or apply one current tier to historical usage spanning account generations.
- Claim OpenAI/Anthropic organization billing data is attributable to an Aiur ticket without a separate reviewed correlation source.
- Reprice historical observations with today's model price or turn unknown cost into `$0.00`.

## Existing owner and reuse target

Build a pure query/projection over DASH-009's `UsageLedger` behavior with a versioned checked-in/configured price table and exact-money helpers. Keep all financial policy outside LiveView.

## Contract and invariants

- Every monetary result carries currency, basis, scope, pricing revision/effective date where applicable, model/token coverage, and retained coverage.
- Unlike bases, currencies, and provider-account generations are never
  arithmetically combined. Unknown contributors remain in token totals and make
  monetary coverage partial/unknown.
- `provider_reported_estimate` is accepted only from a DASH-008/010 source that declares structured estimated request cost; it is not inferred from a subscription fee.
- Current-build membership is caller-supplied current GitHub identity. The query includes all retained observations for each current member, with no membership-time cutoff.
- Historical pricing joins require exact provider, resolved model, token
  dimension, currency, and UTC occurrence-price interval. Tier correlation is
  not a pricing join and is exposed only as an exact opaque-generation key for
  DASH-015; this projection never reads meter snapshots.
- Group sums reconcile exactly to their matching basis/scope/currency/account-generation total; unrelated identities cannot enter through bare-number collisions.

## Refreshable implementation notes

- Seed price fixtures from an explicitly reviewed revision at pickup; record
  source, currency, and inclusive UTC effective dates, validate non-overlapping
  intervals, but perform no runtime web fetch.
- Keep estimates reproducible by storing the revision table in source/config and selecting by the retained UTC occurrence-price bucket. Add a coverage reason when an observation predates known pricing or no exact currency series exists.
- Reconcile #132 as covered/superseded for per-ticket estimate semantics; its TUI-specific rendering remains outside this ticket.

## Acceptance and verification

### Agent gate

- Exact-arithmetic/property tests cover each basis, model/token price dimension, cache/reasoning subsets, UTC effective-date boundaries, non-overlap/ambiguity validation, unknown model/auth/price, mixed bases/currencies/account generations, completed and unrelated tickets, and group-to-total reconciliation.
- Join-safety tests prove pricing never crosses provider or currency, grouped
  output never merges known/unknown or different account generations, and the
  emitted tier key cannot correlate an unknown/mixed generation or authorize a
  provider/backend-only join.
- Scope tests prove current-member pre-membership usage is included, removed/nonmember usage is excluded, bare issue numbers cannot collide, and run versus build labels remain distinct.
- Ledger failure/retention tests cover empty, partial, corrupt/unavailable health and earliest/latest coverage without converting gaps to zero.

### At-merge gate

- Rebase on DASH-009 and the resolved configured integration target; run ledger/replay, pricing/query, exact-money, membership identity, security, regression, and full CI suites. Review price fixtures and policy copy as code/data changes.

### Human/manual evidence

- Executor reviews a synthetic subscription example showing an API-equivalent estimate separately from a provider-reported estimate, verifies the `*`/explanation/tier requirement, and confirms unlike bases, currencies, and account generations are not summed or tier-correlated.

## Failure, security, migration, and accessibility cases

- Missing pricing/model/auth or degraded ledger produces partial/unknown with a reason; it never fails open to a monetary zero.
- Treat grouped financial/Executor facts as sensitive. Do not log query rows, account identity, credentials, or raw provider events.
- Version price tables and output schema. Replay/query migration preserves
  historical basis/revision, currency, occurrence-price partition, and opaque
  account-generation semantics.
- No direct UI; all basis, scope, coverage, and unknown reason fields have human-readable labels for DASH-015.

## Surfaces

- Reads: DASH-009 ledger/query behavior with retained occurrence-price,
  currency, and opaque account-generation partitions; versioned price table;
  explicit typed run/ticket membership sets. It does not read provider meters.
- Writes: cost/usage grouping projection and query API, pricing revisions/fixtures, tests.
- Contracts: exact effective-date/currency pricing, generation-qualified tier
  join key, comparable cost bases, exact grouped summary, current-build
  retained-membership semantics.

## Sibling boundaries and open gates

DASH-010 supplies required Remote Control observations but does not block
developing this projection against fixtures. DASH-012/013 own actual account
tier and quota facts; DASH-011 deliberately does not depend on or join them.
DASH-015 is the sole composition owner that may join usage groups to tier facts,
and only by provider, backend, and the exact known opaque generation. It must
keep bases/currencies/generations separate and apply the subscription estimate
disclosure exactly.
