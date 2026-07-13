# DASH-009 — Persist attributed usage ledger

**Kind:** executable

**Provenance:** planned in plan v1 after storage/accounting adversarial review

**Complexity:** 4 — Crash-safe single-writer audit, replay, checkpoints, and retained aggregate coverage

**Risk:** high

**Depends on:** DASH-008

**Serializes with:** daemon state-directory, durable writer, and usage-ledger changes

**External gate:** `GATE-OCC-PREDECESSOR-BASELINE` — resolve before dispatch

**Requirements:** DREQ-009

**Researched at:** `1e0cfba31c0e6cc4fea14a25e8b4344ef1d6d67d`

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Aiur durably and idempotently retains DASH-008 usage by run, ticket, attempt,
provider-account generation, backend, agent family, exact model,
occurrence-price bucket, currency, and token/cost dimension across retries,
completion, restart, rotation, and corruption without requiring Postgres or
application SQLite.

## Context and evidence

Current accounting disappears with process/run state. Open #132 requests durable per-ticket tokens/cost but proposes a per-issue JSON artifact and TUI surface that cannot provide one daemon-owned multi-dimensional ledger. Open #845 recommends a future Postgres RunLedger for broader BI/cloud work. This bounded local dashboard v1 uses a file-first owner and a behavior seam, explicitly deferring that infrastructure program instead of asking a worker to choose storage architecture.

## Scope

- Implement one supervised single-writer `UsageLedger` behind a behavior. The v1 adapter stores canonical versioned append-only NDJSON segments under Aiur's private daemon state directory, never inside issue workspaces or human-readable agent logs.
- Persist each accepted raw DASH-008 envelope before publishing ledger updates. Maintain the sole durable idempotency and absolute-counter checkpoint keyed by provider, transport, opaque `provider_account_generation`, independent `counter_epoch`, session/thread/turn/request scope, counter kind, model context, cost basis/currency where applicable, and source identity.
- Derive additive token and provider-cost deltas inside the single writer. Absolute measurements advance only a matching durable checkpoint; duplicates and older/out-of-order values add zero, while an unexplained lower value is a coverage/reset error until a new trusted epoch or reset arrives. Source-declared deltas are added only once by durable event identity. Never add overlapping absolute and delta streams unless the source contract declares them independent.
- Make append, checkpoint and aggregate recovery one replayable protocol: after a crash at any boundary, replay the canonical raw envelopes from the last validated checkpoint and reproduce the same deltas exactly. A resumed provider session after daemon restart cannot re-add its prior cumulative total.
- Maintain crash-safe aggregate/checkpoint projections by provider, run, typed ticket, attempt, opaque `provider_account_generation` (including explicit unknown), backend, agent family, exact resolved model, auth mode, DASH-008 `pricing_effective_date`, token dimension, provider-reported cost basis, and exact currency. Write snapshot/checkpoint updates to a same-filesystem temporary file, flush, atomically rename, and preserve enough store-generation/checksum metadata to reject torn or mismatched state.
- On startup, validate the latest checkpoint and replay subsequent canonical segments. If a checkpoint is absent/corrupt, rebuild from retained canonical segments; quarantine a malformed tail/segment with visible health rather than silently truncating valid history.
- Implement bounded segment rotation/retention. Before removing an old raw segment, commit an aggregate snapshot that preserves every downstream grouping partition exactly: provider, run, typed ticket, attempt, backend, agent family, exact resolved model, auth mode, opaque `provider_account_generation`, DASH-008 UTC `pricing_effective_date`, token dimension, monetary basis, and currency, plus exact totals, coverage gaps, and `earliest_covered_at`/`latest_covered_at`. Compaction must never merge different occurrence-price dates, currencies, known/unknown account generations, or any other DASH-011 grouping dimension. “All retained usage” includes compacted aggregates, not only raw events.
- Expose exact snapshot/query primitives, store generation, health, retained coverage interval, and update PubSub. Keep provider/auth/plan facts numeric or enumerated and content-free.
- Document #132 as superseded/covered for storage and accounting; retain its TUI presentation as deferred consumer work. Relate #845 as the deferred Postgres/BI backend and prove the behavior seam can support a later adapter without changing query semantics.

## Non-goals

- Add Postgres, Ecto, application SQLite, a database service, pricing estimates, account meters, dashboard/TUI UI, budget alerts, or prompt/transcript storage.
- Create one mutable JSON file per ticket, parse logs for usage, or make a browser/worker the ledger writer.
- Guarantee retention beyond the configured policy without reporting the retained coverage interval.

## Existing owner and reuse target

Add a daemon-owned supervised writer using existing private state-directory, atomic-file, append-only audit, checksum/version, and PubSub conventions where available. Consume only DASH-008 envelopes and keep transient `TokenAccounting` as a compatibility consumer until separately retired.

## Contract and invariants

- The supervised writer is the only file and delta owner. An envelope is acknowledged persisted only after its canonical append and durable counter/idempotency state are committed according to the documented durability policy.
- Replaying the same canonical segments and checkpoint yields identical derived deltas and exact aggregates. Duplicate/out-of-order input, process restart and resumed cumulative sessions cannot inflate tokens or cost.
- Projection/compaction never merges away provider, ticket, run, attempt,
  backend, agent-family, exact-model, auth-mode, occurrence-price date,
  provider-account-generation, currency, cost-basis, or token-dimension keys
  required by DASH-011.
- `provider_account_generation`, `counter_epoch`, and ledger/store generation
  are three separate namespaces. Counter reset cannot relabel an account,
  account rotation cannot collide checkpoints, and storage recovery cannot
  change either source identity.
- A compacted row remains priceable only within its exact UTC
  `pricing_effective_date` partition. A future price-table revision cannot
  reassign it by ingestion, compaction, checkpoint, or query time.
- Empty healthy data, partial retained coverage, corrupt/unavailable storage, and unknown attribution are distinct states.
- The file adapter is implementation; `UsageLedger` behavior/query semantics are the durable contract for a future #845 backend.

## Refreshable implementation notes

- Reuse proven atomic write helpers if the resolved configured integration target has them; otherwise keep a small dedicated file adapter with injected filesystem/clock/fault hooks.
- Define flush/fsync batching from measured event frequency, but persist-before-publish and crash tests are non-negotiable. Do not let performance tuning weaken acknowledgement semantics.
- Use restrictive owner-only permissions and canonicalized paths beneath the configured Aiur state root.

## Acceptance and verification

### Agent gate

- Deterministic tests cover token and exact-cost absolute-to-delta derivation, source deltas, overlapping-stream policy, duplicate/out-of-order/lower-without-reset envelopes, trusted counter reset/new epoch, provider-account rotation, retry/new attempt, resumed provider sessions, model/backend fallback, completed tickets, process/daemon restart, torn tail, corrupt checkpoint, bad checksum, segment rotation, compaction, retention, and exact rebuilt aggregates.
- Compaction/property fixtures place otherwise-identical observations on
  different UTC occurrence-price dates, currencies, account generations,
  models, auth modes, tickets, attempts, backends, agent families, token
  dimensions, and cost bases and prove every partition and group-to-total sum
  survives rotation/replay unchanged.
- Crash-boundary tests stop after raw append, counter-checkpoint update and aggregate update in turn; every replay produces the same delta exactly once.
- Failure injection covers append, flush, rename, directory, disk-full/permission, and publish ordering; no failure is reported as persisted success.
- Security tests prove owner-only location/permissions, path containment, content redaction, and absence from issue workspaces/logs.

### At-merge gate

- Rebase on DASH-008 and the resolved configured integration target; run usage normalizer, application supervision, durable-file/replay, PubSub, packaging/state-directory, security, and full CI suites. Preserve the documented #132/#845 scope disposition without mutating those existing issues implicitly.

### Human/manual evidence

- From the Executor repository root, record synthetic attributed usage, restart the real daemon, and show identical retained totals/coverage without inspecting or exposing real account data. Corrupt a synthetic copy to demonstrate visible degraded health and recovery.

## Failure, security, migration, and accessibility cases

- Corruption or I/O failure preserves last validated state where safe, marks health/coverage, and stops acknowledgement; it never resets totals to zero.
- Store owner-only normalized numeric/identity facts. Never store prompt/output, raw provider response, credentials, emails/account/org IDs, environment values, capability URLs, or raw workspace paths.
- Schema/segment/checkpoint versions and rebuild/rollback behavior are explicit. A future backend migrates through the behavior contract, not live dual writers.
- No direct UI; health and coverage reasons are stable and human-readable.

## Surfaces

- Reads: DASH-008 raw `UsageEnvelope` stream, including its opaque account
  generation and UTC occurrence-price partition, and private state
  configuration.
- Writes: append-only NDJSON segments, aggregate/checkpoint snapshots, health/generation/coverage projection, PubSub and tests.
- Contracts: `UsageLedger` behavior, sole durable delta/idempotency policy,
  persistence acknowledgement, lossless downstream grouping/coverage,
  replay/compaction semantics.

## Sibling boundaries and open gates

DASH-011 owns all pricing/grouping policy and DASH-015 owns presentation. #132 must not remain a competing active storage design; #845's Postgres/BI work remains separately authorized future scope.
