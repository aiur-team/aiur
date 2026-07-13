# BO-003 — Project atomic planning caches and LKG

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Supervised coalesced refresh with two last-known-good health domains

**Risk:** high

**Phase hint:** 3

**Depends on:** BO-002

**Serializes with:** BO-005

**Requirements:** BOREQ-001, BOREQ-004

**Decisions:** DEC-002, DEC-005

**Design evidence:** DESIGN-002

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:4`, `model:codex`, `phase:3`, `build-lane:backend`; never `agent:todo`

## Outcome

One always-supervised projection supplies a current root catalog, atomic
last-known-good selected-root snapshots, with coalesced demand, bounded refresh,
explicit health/freshness, and no partial generation visible to LiveView.

## Context and evidence

The catalog and selected graph fail independently: a known catalog can remain
usable while one root is malformed or stale, and a selected root can retain a
last-known-good graph when GitHub temporarily fails. Treating both as one empty
state would hide valid roots or clear blockers. LiveView cannot own provider
polling because requests would scale with browser count and disconnects.

## Scope

- Add an always-supervised projection keyed by configured tracker/repository and
  canonical root node ID, with separate catalog and per-selected-root generation
  records.
- Coalesce concurrent catalog/selected-root demand, bound in-flight work and
  retained roots, schedule refresh/retry with observable backoff, and publish
  generation changes over the existing process/PubSub conventions.
- Default catalog refresh to 60 seconds and an actively demanded selected root
  to 15 seconds. On selection or LiveView reconnect, coalesce an asynchronous
  refresh when the relevant snapshot is older than 5 seconds while rendering
  the current snapshot and visible refreshing/freshness state immediately.
  All three positive durations are configurable; the reconnect threshold may
  not exceed the demanded-root interval.
- Build each candidate off-process, validate it fully, and atomically swap only
  after BO-002 returns complete success. Never merge individual pages or edges
  into the visible generation.
- On refresh failure, retain last-known-good data with last-success,
  last-attempt, failure class, staleness, and next-retry metadata. Without an
  LKG, expose unavailable rather than an empty graph.
- Treat BO-002 exact-bound-plus-one, page-budget, and provider-call-budget
  failures like any other preserving failure: retain the prior LKG, mark health
  stale/degraded, and never publish the partial candidate.
- Preserve each catalog entry's validity. One malformed root does not hide
  valid siblings; selecting it yields structural-invalid, which differs from
  catalog unavailable, selected unavailable, or selected stale-LKG.
- Keep member metadata warnings inside otherwise valid selected generations and
  preserve all five edge states for downstream presentation. Never hydrate all
  member bodies to satisfy one selected context.
- Make restart semantics explicit: an in-memory v1 cache starts unavailable
  until refreshed; no stale snapshot is invented after restart.

## Non-goals

- Fold Aiur events, join runtime activity, infer readiness beyond BO-001 pure
  validation, or render browser state.
- Persist LKG across daemon restart, prefetch every member body, implement
  webhook-only consistency, or mutate GitHub.
- Let a LiveView caller select cache policy, perform an ad hoc refresh loop, or
  observe a partially-built candidate.

## Existing owner and reuse target

Reuse Aiur's OTP supervision, task, cache, PubSub, and provider-health patterns.
Do not place this state in `DashboardLive`, `ControlCenterCache`, ordinary issue
polling, or the interactive AgentList process.

## Contract and invariants

- Each published generation is immutable, monotonically identified, complete,
  and tied to its repository/root identity and provider observation time.
- Successful atomic swap broadcasts exactly one generation notification before
  the refresh operation completes; a failed/partial candidate broadcasts only
  a health transition and never a data generation.
- A failed attempt changes health metadata, not the content of the LKG.
- Catalog health, catalog-entry validity, selected-root health, and member
  warnings are independent and remain distinguishable to BO-007/012.
- Unknown or stale dependency data never yields a newly ready ticket.
- Requests and cache retention are bounded independently of connected browsers.

## Refreshable implementation notes

- Refresh current application-supervision and cache APIs before adding the
  child; serialize with BO-005 when both touch those owners.
- Prefer deterministic injected timers/tasks and explicit generation tokens;
  avoid sleep-based tests.
- Keep the 60-second catalog, 15-second demanded-root, and 5-second selection/
  reconnect defaults configurable through existing application configuration,
  with validation and no per-view knobs.

## Acceptance and verification

### Agent gate

- Deterministic tests cover cold start, success, stale LKG, no-LKG failure,
  recovery, concurrent coalescing, out-of-order completion, timeout, retry,
  bounded eviction, provider restart, and subscriber churn without sleeps.
- Injected-clock tests cover each 60/15/5-second boundary at `-1`, exact, and
  `+1`, selection/reconnect coalescing, configurable overrides, and visible LKG
  freshness after failure.
- Catalog tests prove malformed-root isolation and selected structural-invalid
  versus stale/unavailable behavior.
- Generation tests inject a partial/error candidate and prove no member or edge
  from it becomes visible.
- Barrier-based PubSub tests prove exactly one generation notification is
  observable before successful refresh completion, no notification exposes a
  partial candidate, and health-only failure updates are deterministic without
  timing sleeps.

### At-merge gate

- Supervision, PubSub, task/cache, provider, compile/lint/spec, and full CI pass
  on the current configured integration branch.
- Shared supervision changes are reconciled with BO-005 before either merges.

### Human/manual evidence

- None separately; BO-015 verifies live degradation and recovery.

## Failure, security, migration, and accessibility cases

- Store normalized, bounded planning facts only; do not cache auth material or
  raw provider responses.
- Document in-memory restart loss explicitly; durable cache migration is not
  introduced here.
- Health/freshness values must support concise accessible status and exact
  timestamps in the route.

## Surfaces

- Reads: BO-002 catalog/selected candidate operations; application config.
- Writes: supervised catalog/graph LKG projection, cache/task children, PubSub
  topics, and deterministic tests.
- Contracts: catalog snapshot; body-free selected-root generation;
  provider health/freshness; configurable 60/15/5-second demand/refresh API;
  atomic generation/health PubSub notification policy.

## Sibling boundaries and open gates

BO-007/012 consume catalog/graph snapshots. BO-016 separately owns
root-independent on-demand ticket detail and its cache. BO-005 owns only Aiur
activity and shares no data contract, but the two tickets serialize on
supervision changes. A companion shell may reuse provider status components
later without becoming a dependency.
