# DASH-005 — Persist attributed usage observations

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Durable idempotent cross-provider event ledger

**Risk:** high

**Depends on:** none

**Requirements:** DREQ-005

**Researched at:** 3d67b7be722eb649f28088fc8d609dd7b75254c7

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Aiur durably records normalized token and raw provider-reported cost observations by run, ticket, attempt, session/turn, backend, agent family, and resolved model across retries, fallback, completion, and restart.

## Context and evidence

Current `TokenAccounting` is in-memory and completed-ticket/current-run data disappears. Claude completion already exposes `cost_usd`, while Codex provides richer cached/reasoning counters; current accounting does not retain provider/model/run/attempt identity together.

## Scope

- Define a versioned provider-neutral observation with idempotency key, observed time, run/tracker/ticket/attempt/session/turn identity, backend/agent family/requested+resolved model/effort/auth mode, token dimensions, and raw provider cost.
- Ingest normalized events after protocol normalization and before transient accounting loss; convert cumulative counters to monotonic deltas per correct provider/session/thread/turn key.
- Persist atomically with checkpoint/replay, health separate from zero, bounded retention/compaction, persist-before-broadcast, and schema migration/rebuild behavior.
- Keep `claude` and `claude-repl` distinct; store explicit incomplete/unsupported coverage rather than zero.
- Redact credentials, emails, capability URLs, prompts, transcripts, output, raw environment and provider responses.

## Non-goals

- Apply versioned prices, allocate subscriptions, compute grouped summaries, fetch quota/account meters, or render dashboard cards.
- Use workspace logs or browser/provider credential stores as ingestion.

## Existing owner and reuse target

Extend the normalized event path around `AgentRunner.MessageHandler`, `Aiur.Orchestrator.TokenAccounting`, `Aiur.Boot.run_id/0`, and Claude/Codex normalizers with a dedicated durable store.

## Contract and invariants

- Duplicates/out-of-order cumulative updates add no incorrect tokens; new attempts/sessions start distinct checkpoints.
- Every observation has exact attribution or explicit unknown identity/coverage; unknown is not zero.
- Raw provider-reported cost is preserved with its basis and currency precision, not mixed with estimates.
- Durability failure is visible and never acknowledged as persisted success.

## Refreshable implementation notes

- Measure write frequency and choose SQLite or append-only audit+projection using existing durable-store patterns; record the choice.
- Exact turn identity may require threading identifiers earlier—keep that contained in this ticket.

## Acceptance and verification

### Agent gate

- Tests cover restart/replay, retry, fallback, duplicate/out-of-order, cache/reasoning tokens, completed tickets, corruption, compaction, unsupported RC, and redaction.
- Failure injection proves persist-before-broadcast and health/unknown behavior.

### At-merge gate

- Protocol normalization, store migration/replay, durability, and full current-base CI pass.

### Human/manual evidence

- No separate human evidence.

## Failure, security, migration, and accessibility cases

- Financial/operator data stays authenticated and redacted; never store content.
- Version/migration/rollback and corruption recovery are explicit.
- No direct UI; coverage/error labels remain human-readable.

## Surfaces

- Reads: normalized Codex/Claude usage events; run/ticket/session identity.
- Writes: durable usage observation audit/projection.
- Contracts: UsageObservation schema and idempotent ingestion.

## Sibling boundaries and open gates

DASH-006 owns pricing/grouping. DASH-007 owns account meters. DASH-008 renders. Build Order membership may filter queries later but does not block ingestion.

