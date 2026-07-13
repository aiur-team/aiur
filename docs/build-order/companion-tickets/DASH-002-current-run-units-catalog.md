# DASH-002 — Project canonical current-run Units

**Kind:** executable

**Provenance:** planned in plan v1 after refreshed-prototype and current-main review

**Complexity:** 4 — Canonical current-run membership, multi-signal predicates, and provenance-rich rows

**Risk:** high

**Depends on:** BO-005

**Serializes with:** none after BO-005 lands

**Requirements:** DREQ-002

**Researched at:** `b7c4e7c06b8c7011f306ce9efb0b9cd8fd8cbac5`

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Aiur exposes one headless-safe current-run Units catalog with explicit membership, terminal retention, source-backed row facts, and a pure truth table for Live/Unfinished/All/None scope plus independent Active/Alert/Paused/Stuck/Queued/Finished conditions.

## Context and evidence

Current main already combines running, retrying, and idle rows in one Fleet table, but the Orchestrator snapshot is not an all-state current-run catalog and does not carry every model, complexity, progress, or terminal fact required by the refreshed design. BO-004 establishes trusted event identity, BO-005 creates the shared TicketActivity projection, and BO-006 migrates the existing AgentList consumer. This ticket depends on the projection contract and coordinates with the migration instead of creating a second event fold.

## Scope

- Define current-run membership as every typed ticket identity observed in the active `run_id` as queued, retrying, allocated, running, paused, waiting, or terminal. Retain terminal rows until that run ends. A daemon restart starts a new current-run generation; prior-run rows belong to history, not this catalog.
- Join BO-005's shared activity with current Orchestrator/tracker issue facts and Decision counts. Expose typed tracker/repository/issue identity, title and trusted URL, lifecycle, waiting/blocking reason, backend, agent family, requested/resolved model, effort, complexity, optional build lane, progress with source/freshness, latest evidence, runtime timestamps, open Command count, and provider health. Missing data remains unknown.
- Define the single-select scope truth table:
  - `Live`: a worker is allocated or actively retained by the runtime, including working, alerting, operator-paused, and stuck units;
  - `Unfinished`: `Live` plus queued, dependency-waiting, and retry-waiting units that are not terminal;
  - `All`: every current-run member, including terminal rows;
  - `None`: no rows.
- Define independent, overlapping condition predicates: `Active` means currently executing work; `Alert` means an open operator/supervisor Command or explicit error attention; `Paused` means authoritative operator/runtime pause; `Stuck` means unresponsive or backing off beyond the accepted threshold; `Queued` means unfinished without an allocated executing worker; `Finished` means a terminal tracker/runtime outcome observed in this run. Unknown state satisfies none of these predicates.
- Define filter composition: apply the selected scope first; no selected condition chip means no condition refinement; one or more selected chips use OR within the condition set. A row is visible when it is in scope and matches any selected condition. Predicate counts are calculated over the selected scope before condition refinement, so overlapping counts are allowed and are not presented as a partition.
- Define a versioned URL codec for scope and selected conditions, canonical ordering, unknown-value removal, defaults, and zero-result reset. Expose pure snapshot, lookup, predicate, count, and URL encode/decode APIs; render no LiveView UI here.

## Non-goals

- Render the Units page, add mutation controls, fetch usage/cost meters, implement Commands, or implement the Build Order graph.
- Create a second TicketActivity reducer, infer finished rows from recent PR text, or retain prior-run rows in the current-run view.
- Treat runtime progress as GitHub completion, convert missing values to zero, or make condition counts sum to the catalog total.

## Existing owner and reuse target

Build a Units catalog/policy layer over the BO-005 TicketActivity consumer, `Aiur.Orchestrator` snapshots, canonical tracker `Issue` values, and Decision projections. Reuse typed identity and freshness contracts rather than keying by bare issue number.

## Contract and invariants

- `run_id` plus typed issue identity uniquely keys a row. Terminal retention lasts through the current run and does not depend on current AgentList visibility.
- Lifecycle scope and condition predicates are separate. Multi-signal rows may satisfy several condition counts without being forced into the prototype's exclusive priority bucket.
- Counts and visible-row filtering call the same pure predicates. URL decoding cannot create a state the policy API itself cannot represent.
- Every optional row fact carries source/freshness or is unknown. Unknown progress, model, provider health, or lifecycle is never `0`, Active, Finished, or healthy by default.
- Waiting reason, blocking reason, and alert reason remain distinct even when a row matches multiple conditions.

## Refreshable implementation notes

- Refresh the final BO-004/005 snapshot names and lifecycle values at pickup. Add a compatibility adapter if names changed; do not fork their reducers.
- Keep policy and URL codec modules free of LiveView dependencies so the dashboard, API, and tests share one truth table.
- Characterize current Fleet filter behavior before replacement, especially waiting reasons, safe tracker URLs, Decision counts, retrying rows, and provider degradation.

## Acceptance and verification

### Agent gate

- Pure policy tests cover every scope and multi-signal combination, including alert+paused, alert+stuck, queued+dependency-waiting, terminal+stale activity, conflicting labels, and wholly unknown rows.
- Catalog tests cover run transition, retry and fallback, pause/resume, terminal retention, typed-identity collisions, provider failure, stale progress, and no prior-run leakage.
- URL/count property tests prove canonical round trips, invalid-value recovery, count/filter parity, and overlapping counts.

### At-merge gate

- Rebase over BO-005 and current main; run shared activity, AgentList, Orchestrator, Decision, presenter compatibility, and full CI suites with no duplicate event subscriptions or row folds.

### Human/manual evidence

- No separate visual evidence. DASH-003 owns the real-dashboard proof against this contract.

## Failure, security, migration, and accessibility cases

- Provider failure preserves last-known-good row facts with health/freshness; it does not remove a current-run member or clear a waiting reason.
- Rows and URLs contain no raw workspace path, prompt, transcript, credentials, account identity, capability URL, or environment value.
- Run-generation migration is additive and ephemeral; no historical analytics store is created here.
- Human-readable status/reason strings are part of the projection so consumers do not rely on color or private atoms alone.

## Surfaces

- Reads: BO-005 TicketActivity snapshot, Orchestrator/tracker issues, Decision counts, current `run_id`.
- Writes: current-run Units catalog process or projection, pure policy/URL codec, PubSub change events, tests.
- Contracts: `UnitsRow`, current-run membership/retention, scope/condition truth table, count and URL codec APIs.

## Sibling boundaries and open gates

DASH-003 renders this contract and DASH-005 adds authenticated controls. DASH-014 computes aggregate run status without changing row predicates. Build Order may supply optional lane/complexity facts, but this catalog remains usable when those fields are unknown.
