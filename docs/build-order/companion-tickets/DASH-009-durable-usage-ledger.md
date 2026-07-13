# DASH-009 — Persist canonical usage ledger

**Kind:** executable

**Provenance:** planned in plan v1 after storage-program split

**Complexity:** 4 — Crash-safe single-writer append, idempotency, counter delta, checkpoint, and replay authority

**Risk:** high

**Depends on:** DASH-008

**Serializes with:** none — aggregate/query and compaction consumers are hard-ordered

**External gate:** `GATE-OCC-PREDECESSOR-BASELINE` — resolve before dispatch

**Requirements:** DREQ-009

**Researched at:** `9849f32963c2a65367bce565b3f5ede3777c218f`

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Aiur durably and idempotently appends DASH-008 measurements and derives each additive token/provider-cost delta exactly once across retry, out-of-order input, process/daemon restart, and corrupt/torn checkpoint recovery.

## Context and evidence

Current accounting disappears with process/run state. The accepted local-first architecture uses one daemon-owned file writer instead of per-ticket JSON, opencode SQLite, Postgres, or a browser writer. Aggregate query projection and retention/compaction are independently testable programs owned by DASH-024 and DASH-025; this ticket establishes the canonical raw authority and replay semantics they consume.

## Scope

- Implement one supervised single-writer `UsageLedger` core behind a behavior. Store canonical versioned append-only NDJSON segments beneath Aiur's private daemon state root.
- Persist each accepted DASH-008 envelope before publishing its accepted ledger position/generation.
- Maintain the sole durable idempotency and absolute-counter checkpoint keyed by provider, transport, opaque account generation, independent counter epoch, session/thread/turn/request scope, counter kind, model context, monetary basis/currency, and source identity.
- Derive additive token and provider-cost deltas inside the writer. Matching absolute counters advance one durable checkpoint; duplicate/older input adds zero; unexplained decrease is a coverage/reset error until a trusted epoch/reset. Source deltas add once by durable event identity.
- Never add overlapping absolute/delta streams unless the source contract declares them independent.
- Make raw append and counter/idempotency checkpoint one replayable acknowledgement protocol. Crash at any boundary and replay must reproduce the same deltas exactly once; resumed cumulative sessions cannot re-add earlier totals.
- On startup, validate checkpoint/schema/checksum and replay subsequent canonical observations. Rebuild durable counter/idempotency state from raw segments when safe; quarantine malformed tail/segment with explicit health instead of silently truncating valid history.
- Expose append acknowledgement, ordered replay/scan behavior, accepted derived-delta stream, store generation, raw coverage bounds, and health. DASH-024 is the only aggregate/query subscriber.
- Preserve restrictive permissions/path containment and content-free normalized facts.

## Non-goals

- Build aggregate/query snapshots, publish grouped totals, rotate/delete/compact segments, apply retention, calculate prices, render UI, add Postgres/Ecto/SQLite, or write per-ticket files.
- Parse logs, accept multiple writers, or acknowledge persistence before canonical append/checkpoint policy succeeds.
- Guarantee retained query coverage; DASH-024/025 own projected and retained coverage.

## Existing owner and reuse target

Add one daemon-owned writer using existing private-state, atomic/checksummed file, append-only audit, injected filesystem/clock, and supervision conventions. Consume only DASH-008 envelopes and retain transient `TokenAccounting` as a compatibility consumer until separately retired.

## Contract and invariants

- The supervised writer is the sole raw append, idempotency, counter checkpoint, and delta owner.
- Replay of the same canonical segments/checkpoint yields identical ordered deltas and never inflates usage.
- `provider_account_generation`, `counter_epoch`, and ledger/store generation remain distinct namespaces.
- Persistence acknowledgement follows documented append/checkpoint durability; an I/O failure never returns success.
- Empty healthy, partial raw coverage, corrupt/unavailable storage, rejected measurement, and unknown attribution are distinct.
- The file adapter is implementation; append/replay/delta behavior is the stable future-backend seam.

## Refreshable implementation notes

- Reuse proven atomic/private-state helpers if present; otherwise keep a dedicated adapter with injected fault points.
- Define flush/fsync batching from measured frequency without weakening persist-before-publish acknowledgement.
- Keep writer, record codec, counter policy, checkpoint, replay, and health modules separately testable under repository size limits.

## Acceptance and verification

### Agent gate

- Deterministic tests cover absolute-to-delta tokens/cost, source deltas, duplicates, out-of-order/lower-without-reset, trusted epoch reset, account rotation, retry/attempt, resumed sessions, fallback/model changes, and completed tickets.
- Crash tests stop after append and counter/idempotency checkpoint boundaries; replay emits every delta exactly once.
- Recovery tests cover missing/corrupt checkpoint, torn tail, bad checksum/schema, malformed segment, process/daemon restart, and safe quarantine.
- Failure injection covers append, flush, rename, directory, disk-full/permission, and publish ordering; no failed path acknowledges success.
- Security tests prove owner-only path containment and absence from issue workspaces/logs.

### At-merge gate

- Rebase on DASH-008 and the resolved configured integration target; run usage normalizer, supervision, durable file/replay, compatibility, packaging/state-directory, security, and full CI suites.

### Human/manual evidence

- Record synthetic attributed usage, restart the real daemon, replay the same cumulative source, and show identical derived deltas without exposing account data. Corrupt a synthetic copy and demonstrate visible health/quarantine.

## Failure, security, migration, and accessibility cases

- I/O/corruption preserves the last validated raw authority where safe, stops acknowledgement, and never resets usage to zero.
- Store only normalized numeric/opaque identity facts, never prompts/output, raw provider response, credentials, account PII, environment values, capability URLs, or paths.
- Version record/checkpoint/replay behavior and rollback. A future backend migrates through the behavior, never live dual writers.
- No direct UI; rejection/health/coverage classes are stable and human-readable.

## Surfaces

- Reads: DASH-008 `UsageEnvelope` stream and private state configuration.
- Writes: canonical append-only segments, idempotency/counter checkpoints, ordered derived-delta stream, health/generation.
- Contracts: sole durable append/delta/replay acknowledgement behavior.
- Safety: exactly-once accounting, crash consistency, owner-only content-free storage.

## Sibling boundaries and open gates

DASH-024 alone builds aggregate/query state from this raw authority. DASH-025 later owns rotation/retention/compaction. DASH-011 cannot read raw files directly. #132/#845 remain separately dispositioned and cannot create a competing writer.
