# DASH-008 — Normalize attributed usage envelopes

**Kind:** executable

**Provenance:** planned in plan v1 after usage/accounting adversarial review

**Complexity:** 4 — Cross-provider measurement semantics and exact attribution at protocol boundaries

**Risk:** high

**Depends on:** BO-004, DASH-018

**Serializes with:** BO-005 and Codex/Claude normalizer, MessageHandler, and token-event changes

**External gate:** `GATE-OCC-PREDECESSOR-BASELINE` — resolve before dispatch

**Requirements:** DREQ-008

**Researched at:** `9849f32963c2a65367bce565b3f5ede3777c218f`

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Every supported Codex and Claude headless usage source emits one
provider-neutral, exactly attributed raw measurement envelope whose counter
scope, account namespace, occurrence-price partition, and delta/absolute
semantics give the DASH-009 single writer everything needed to prevent
duplicate, overlapping, cross-account, or historically repriced accounting.

## Context and evidence

Current `Aiur.Orchestrator.TokenAccounting` is transient, while `Aiur.TokenUsage.canonicalize/1` zero-fills missing dimensions and omits cache/reasoning detail. Codex can expose cumulative thread updates and turn usage in the same session; Claude completion data has different per-request semantics and may already include provider-reported cost. Treating every map as the same cumulative counter can double count. BO-004 establishes the shared activity event seam; this ticket starts there and serializes with BO-005 rather than adding a competing fold during migration.

## Scope

- Define a versioned `UsageEnvelope` with:
  - stable idempotency key, trusted RFC 3339 UTC `occurred_at`, derived
    `pricing_effective_date`, and daemon `ingested_at`;
  - typed run, tracker, repository/project, issue, attempt, session, thread, turn, and request identity where available;
  - agent family, provider, backend, transport, auth mode, effort, requested model, exact resolved model, and opaque `provider_account_generation`;
  - `measurement_kind` (`delta` or `absolute`), `counter_scope` (`request`, `turn`, `thread`, or `session`), independent `counter_epoch`, source event ID/sequence, and update kind (`full` or `partial`);
  - raw token dimensions for input, cached input, cache-creation input, output, and reasoning output, plus provider-reported total;
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
- Define token overlap semantics: cached and cache-creation tokens are input subdimensions and reasoning is an output subdimension unless a provider contract says otherwise. Preserve each dimension, but canonical total uses provider-reported total when available and otherwise non-overlapping input plus output; it never sums every subdimension.
- Normalize existing Codex and Claude headless protocol events before transient accounting loss. Classify each source event as absolute or delta at its true scope and preserve the raw source counters unchanged. Do not derive a cross-message delta here.
- Generate deterministic idempotency identity from trusted source event identity. Preserve source order, `provider_account_generation`, and independent counter-reset evidence so DASH-009 can reject duplicates, out-of-order values and an unexplained lower absolute value durably.
- Capture provider cost as exact decimal/integer minor units at decode time, before float conversion. A missing or imprecise value is unknown, not zero.
- Emit normalized envelopes unconditionally for normal runs, independent of browser count, interactive TUI presence, or `--debug`. Strip raw payloads after normalization.

## Non-goals

- Persist envelopes or counter checkpoints, derive cross-message deltas, calculate versioned estimates, fetch account/quota meters, support Claude REPL/Remote Control, render UI, or replace BO-004's activity projection.
- Infer auth mode/model/ticket identity from prose, workspace basename alone, email/account IDs, or browser state.
- Mint or own a meter-only or usage-only account namespace, derive the opaque
  account generation from stable account PII, or treat counter reset as account
  change.
- Treat cached/reasoning dimensions as additional tokens on top of reported input/output or coerce missing fields to zero.

## Existing owner and reuse target

Extend the normalized event path around Codex/Claude event normalizers, `AgentRunner.MessageHandler`, BO-004's accepted activity seam, `Aiur.Boot.run_id/0`, trusted worker/session metadata, and DASH-018's provider-account-generation lookup. Keep lifecycle reporting at trusted adapter boundaries without duplicating DASH-018's owner.

## Contract and invariants

- Measurement kind, counter scope, `counter_epoch`, and source event identity are mandatory whenever a resettable numeric counter is present; otherwise the numeric field is rejected as unsupported/unknown.
- The raw identity fields required for DASH-009's durable delta key include provider, transport, `provider_account_generation`, `counter_epoch`, session/thread/turn/request scope, counter kind, currency/cost basis where applicable, and model context—not merely ticket ID.
- One envelope represents one raw source measurement. A thread absolute update and turn delta may both be retained, but DASH-009 can distinguish overlapping streams and applies the only additive/dedup policy.
- `occurred_at` records trusted source event time; `pricing_effective_date`
  records its exact UTC daily partition; `ingested_at` records daemon receipt.
  Ordering, deduplication, and pricing never substitute receipt time for missing
  source identity or occurrence time.
- Usage without a trusted provider-account binding remains explicitly
  uncorrelated. It may contribute to generation-unknown token groups, but it
  can never join a plan/tier snapshot or another known generation.
- Only trusted runtime context supplies run/ticket/attempt/backend/model attribution. Missing attribution remains explicit and cannot leak usage into another ticket.

## Refreshable implementation notes

- Capture fixtures from the installed Codex and Claude headless protocol versions at pickup; protocol drift is expected. Record each event method and its measured scope alongside fixtures.
- Read the opaque generation through DASH-018's trusted runtime contract; never
  copy a raw account identifier into the normalized schema or mint a local value
  to make the later join convenient.
- Preserve compatibility for existing transient token consumers through an adapter while directing durable consumers to `UsageEnvelope`.
- Use Decimal or integer micros/minor units at JSON decode/normalization; do not decode monetary values through a float first.

## Acceptance and verification

### Agent gate

- Fixture/property tests cover faithful classification of Codex cumulative thread updates plus turn completion, Claude request deltas, duplicates, out-of-order events, counter reset/new epoch without account rotation, account rotation without counter collision, retry/new attempt, session resume, backend/model fallback, partial updates, cache/reasoning subsets, UTC date-boundary buckets, missing occurrence time, and unknown fields without stateful delta derivation.
- Exact-arithmetic tests prove provider cost survives decoding without float drift and canonical totals do not double count subdimensions.
- Attribution/security tests cover DASH-018 shared generation consumption, typed identity collision, missing/unknown generation, forged prose/model fields, account rotation observed through the owner, and complete raw-payload/account/credential redaction.

### At-merge gate

- Rebase on BO-004 and serialize with BO-005/current protocol work; run Codex/Claude normalizer, MessageHandler, activity/token compatibility, protocol fixture, security, and full CI suites.

### Human/manual evidence

- No separate visual evidence. Record sanitized synthetic raw envelopes from one real Codex and one real Claude headless turn and show their source scope, identity and measurement classification; DASH-009 owns the resulting delta proof.

## Failure, security, migration, and accessibility cases

- Malformed, ambiguous, or unattributable usage is rejected/recorded as coverage failure without crashing the agent or becoming zero usage.
- Never retain raw provider response, prompt/output, email/account/org, credential, OAuth/API material, environment value, capability URL, or workspace path in an envelope.
- Version the envelope and compatibility adapter; downstream tickets must support replay/migration by schema version.
- No direct UI; unknown/coverage reasons use stable human-readable classes.

## Surfaces

- Reads: normalized Codex/Claude headless protocol events; trusted run/ticket/attempt/session/backend/model context; DASH-018 account generation.
- Writes: raw `UsageEnvelope` schema/normalizers, trusted lifecycle observations to DASH-018, event publication, fixtures and tests.
- Contracts: provider account versus counter-epoch identity, occurrence-price bucket, measurement semantics, token overlap/total policy, exact provider-cost representation, attribution/redaction.

## Sibling boundaries and open gates

DASH-018 owns the sole `provider_account_generation` namespace. DASH-009 owns
durable counter checkpoints, delta derivation, deduplication and ledger;
DASH-010 owns Claude REPL/Remote Control event normalization; DASH-011 owns
estimates/grouping; DASH-012 owns the meter contract. BO-004 remains runtime
activity truth, and accounting never becomes a Build Order completion
dependency.
