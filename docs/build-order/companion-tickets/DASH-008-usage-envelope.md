# BO: DASH-008 — Define attributed usage envelopes

**Kind:** executable

**Provenance:** planned in plan v1 after usage/accounting adversarial review

**Complexity:** 3 — Provider-neutral measurement, relationship, attribution, and exact-money contract

**Risk:** high

**Phase hint:** 3

**Depends on:** BO-017, DASH-018

**Serializes with:** none

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-008

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:3`, `model:codex-gpt-5.6-terra`, `phase:3`, `build-lane:accounting`; never `agent:todo`

**Build Order membership:** member of the consolidated Build Order (operator decision 2026-07-13)

## Outcome

Aiur has one provider-neutral, exactly attributed raw measurement contract
whose counter scope, account namespace, occurrence-price partition, delta/
absolute semantics, exact money, and pinned provider/source relationship
revision let adapters, DASH-009, and DASH-011 prevent duplicate, overlapping,
cross-account, or historically repriced accounting without guessing token
relationships.

## Context and evidence

Current `Aiur.Orchestrator.TokenAccounting` is transient, while
`Aiur.TokenUsage.canonicalize/1` zero-fills missing dimensions and omits cache/
reasoning detail. Codex and Claude sources have different counter and cache
semantics, so adapters need an immutable common contract before DASH-029 maps
their versioned events. BO-017 and DASH-018 supply the trusted identity and
account-generation contracts consumed here.

## Scope

- Define a versioned `UsageEnvelope` with:
  - stable idempotency key, trusted RFC 3339 UTC `occurred_at`, derived
    `pricing_effective_date`, and daemon `ingested_at`;
  - typed run, tracker, repository/project, issue, attempt, session, thread, turn, and request identity where available;
  - agent family, provider, backend, transport, auth mode, effort, requested model, exact resolved model, and opaque `provider_account_generation`;
  - `measurement_kind` (`delta` or `absolute`), `counter_scope` (`request`, `turn`, `thread`, or `session`), independent `counter_epoch`, source event ID/sequence, and update kind (`full` or `partial`);
  - raw token dimensions for input, cached input, cache-creation input, output,
    and reasoning output, plus provider-reported total and a pinned
    `token_relationship_revision`;
  - optional exact-decimal provider-reported cost, currency, cost measurement kind/scope, source/version, and explicit coverage/unknown reasons.
- Consume DASH-018's sole shared `provider_account_generation` for every
  envelope. Usage normalizers report trusted provider/auth lifecycle evidence
  through DASH-018 when they own it, but they never mint, rotate, persist, or
  infer a usage-local generation.
- Keep `provider_account_generation` distinct from `counter_epoch`. An account
  generation partitions account/tier correlation; a counter epoch partitions
  resettable cumulative streams and may rotate without claiming the account
  changed. Neither value may be substituted for the other in identity,
  checkpoint, grouping, or join keys.
- Define `pricing_effective_date` as the UTC Gregorian date (`YYYY-MM-DD`) whose
  half-open bucket is `[00:00:00Z, next-day 00:00:00Z)` and contains trusted
  `occurred_at`. It is a deterministic occurrence partition, not a selected
  price revision. Missing or untrusted source occurrence time yields explicit
  unknown pricing coverage; `ingested_at` must never choose this bucket.
- Own a versioned token-relationship registry keyed by `(provider, source,
  source_version)`. Each token-bearing source revision declares every raw
  dimension as `additive`, `subset_of:<parent>`,
  `mutually_exclusive:<group>`, or `unknown`, and independently declares
  whether a structured provider-reported total is authoritative. Pin the
  selected registry revision on the envelope so replay, aggregate projection,
  compaction, and pricing retain the exact interpretation used at ingestion.
- Preserve every raw dimension. When an authoritative provider total is
  present, use it as canonical total and expose any dimensional discrepancy as
  coverage/reconciliation evidence. Otherwise derive a total only when all
  contributing relationships are known: add disjoint dimensions, count a
  subset through its parent once, and accept at most one nonzero alternative
  in a mutually exclusive group. Missing, unknown, or contradictory
  relationships fail closed: an explicitly authoritative provider total may
  remain canonical with partial dimension coverage, but otherwise the total is
  unknown, and no dimension-derived pricing input is published.
- Define deterministic idempotency identity requirements over trusted source
  event identity. Preserve source order, `provider_account_generation`, and
  independent counter-reset evidence so DASH-009 can reject duplicates, out-
  of-order values, and unexplained lower absolute values durably.
- Capture provider cost as exact decimal/integer minor units at decode time, before float conversion. A missing or imprecise value is unknown, not zero.
- Define validation, serialization, compatibility, and bounded human-readable
  rejection/coverage reason contracts. Provider adapters must strip raw
  payloads after normalization and emit independently of browser/TUI/debug
  state, but DASH-029 owns that runtime wiring.

## Non-goals

- Implement Codex/Claude headless adapters, persist envelopes or checkpoints,
  derive cross-message deltas, calculate estimates, fetch account/quota meters,
  support Claude REPL/Remote Control, render UI, or replace BO-005's activity
  projection.
- Infer auth mode/model/ticket identity from prose, workspace basename alone, email/account IDs, or browser state.
- Mint or own a meter-only or usage-only account namespace, derive the opaque
  account generation from stable account PII, or treat counter reset as account
  change.
- Apply one global cache/reasoning assumption, silently choose between
  conflicting mutually exclusive dimensions, treat any provider total as
  authoritative without a versioned source contract, or coerce missing fields
  to zero.

## Existing owner and reuse target

Define the `UsageEnvelope`, token-relationship registry, validation, exact-money
decode helpers, and compatibility behavior around BO-017's propagated identity,
`Aiur.Boot.run_id/0`, trusted worker/session metadata, and DASH-018's account-
generation lookup. Keep provider event methods and lifecycle wiring in
DASH-029/010.

## Contract and invariants

- Measurement kind, counter scope, `counter_epoch`, and source event identity are mandatory whenever a resettable numeric counter is present; otherwise the numeric field is rejected as unsupported/unknown.
- The raw identity fields required for DASH-009's durable delta key include provider, transport, `provider_account_generation`, `counter_epoch`, session/thread/turn/request scope, counter kind, currency/cost basis where applicable, and model context—not merely ticket ID.
- One envelope represents one raw source measurement. A thread absolute update and turn delta may both be retained, but DASH-009 can distinguish overlapping streams and applies the only additive/dedup policy.
- Every token-bearing envelope identifies the selected relationship revision,
  or explicit unknown, matching its provider/source/source version. Unknown
  revisions may preserve bounded raw evidence with explicit coverage failure,
  but cannot publish a derived canonical total or API-equivalent pricing input.
  Provider-total authority never discards the dimension-level reconciliation
  record.
- `occurred_at` records trusted source event time; `pricing_effective_date`
  records its exact UTC daily partition; `ingested_at` records daemon receipt.
  Ordering, deduplication, and pricing never substitute receipt time for missing
  source identity or occurrence time.
- Usage without a trusted provider-account binding remains explicitly
  uncorrelated. It may contribute to generation-unknown token groups, but it
  can never join a plan/tier snapshot or another known generation.
- Only trusted runtime context supplies run/ticket/attempt/backend/model attribution. Missing attribution remains explicit and cannot leak usage into another ticket.

## Refreshable implementation notes

- Use provider-neutral synthetic fixtures plus explicit registry examples.
  DASH-029/010 capture installed protocol fixtures and bind exact source
  versions at pickup.
- Read the opaque generation through DASH-018's trusted runtime contract; never
  copy a raw account identifier into the normalized schema or mint a local value
  to make the later join convenient.
- Define the compatibility projection required by existing transient token
  consumers; DASH-029 wires it at provider boundaries.
- Use Decimal or integer micros/minor units at JSON decode/normalization; do not decode monetary values through a float first.

## Acceptance and verification

### Agent gate

- Schema/property tests cover delta/absolute scopes, duplicates and source
  identity requirements, counter epoch versus account generation, retry/
  attempt/session/model attribution, partial updates, Claude-style additive
  cache dimensions, Codex-style subsets, mutually exclusive alternatives,
  provider-total authority/discrepancy, UTC date-boundary buckets, missing
  occurrence time, and unknown relationships without stateful delta derivation.
- Exact-arithmetic tests prove provider cost survives decoding without float
  drift; additive, subset, and mutually exclusive fixtures reconcile exactly;
  and unknown or contradictory relationships never produce a guessed total.
- Attribution/security tests cover DASH-018 shared generation consumption, typed identity collision, missing/unknown generation, forged prose/model fields, account rotation observed through the owner, and complete raw-payload/account/credential redaction.

### At-merge gate

- Rebase on BO-017/DASH-018 and pass envelope schema, relationship registry,
  exact-money, compatibility-contract, security, and full CI suites. DASH-029
  separately sequences shared normalizer work with BO-005.

### Human/manual evidence

- No separate visual evidence. Review sanitized provider-neutral examples for
  additive, subset, mutually exclusive, provider-total, exact-money, and
  unknown cases; DASH-029/010 own real source mappings and DASH-009 owns the
  resulting durable delta proof.

## Failure, security, migration, and accessibility cases

- Malformed, ambiguous, unattributable, or relationship-unknown usage is
  rejected/recorded as coverage failure without crashing the agent, becoming
  zero usage, or silently acquiring additive semantics.
- Never retain raw provider response, prompt/output, email/account/org, credential, OAuth/API material, environment value, capability URL, or workspace path in an envelope.
- Version the envelope and compatibility adapter; downstream tickets must support replay/migration by schema version.
- No direct UI; unknown/coverage reasons use stable human-readable classes.

## Surfaces

- Reads: BO-017 trusted run/ticket/attempt/session/backend/model identity and
  DASH-018 account-generation contract.
- Writes: `UsageEnvelope` schema, token-relationship registry, validation/
  serialization/exact-money helpers, compatibility contract, fixtures, and
  tests.
- Contracts: provider account versus counter-epoch identity, occurrence-price
  bucket, measurement semantics, versioned provider/source token-dimension
  relationships and provider-total authority, exact provider-cost
  representation, attribution/redaction.

## Sibling boundaries and open gates

DASH-018 owns the sole `provider_account_generation` namespace. DASH-029 owns
Codex/Claude headless source mappings and BO-005 serialization; DASH-009 owns
durable counter checkpoints, delta derivation, deduplication, and ledger;
DASH-010 owns Claude REPL/Remote Control mapping; DASH-011 owns pricing;
DASH-030 owns grouping; and DASH-012 owns meters. BO-017 owns propagated
identity while StatusReport remains runtime activity truth. Accounting never
becomes a Build Order completion dependency.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-008`
- [Graph waves, critical path, and parallelism](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
