# DASH-002 — Project canonical current-run Units

**Kind:** executable

**Provenance:** planned in plan v1 after refreshed-prototype and current-main review

**Complexity:** 4 — Canonical current-run membership, multi-signal predicates, and provenance-rich rows

**Risk:** high

**Depends on:** BO-005

**Serializes with:** none after BO-005 lands

**External gate:** `GATE-OCC-PREDECESSOR-BASELINE` — resolve before dispatch

**Requirements:** DREQ-002

**Researched at:** `1e0cfba31c0e6cc4fea14a25e8b4344ef1d6d67d`

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Aiur exposes one headless-safe current-run Units catalog with explicit membership, terminal retention, source-backed row facts, and a pure truth table for Live/Unfinished/All/None scope plus independent Active/Alert/Paused/Stuck/Queued/Finished conditions.

## Context and evidence

Current main already combines running, retrying, and idle rows in one Fleet table, but the Orchestrator snapshot is not an all-state current-run catalog and does not carry every model, complexity, progress, or terminal fact required by the refreshed design. BO-004 establishes trusted event identity, BO-005 creates the shared TicketActivity projection, and BO-006 migrates the existing AgentList consumer. This ticket depends on the projection contract and coordinates with the migration instead of creating a second event fold.

## Scope

- Define current-run membership as every typed ticket identity observed in the active `run_id` as queued, retrying, allocated, running, paused, waiting, or terminal. DASH-002 owns that membership set and retains terminal rows until the run ends. A daemon restart starts a new current-run generation; prior-run rows belong to history, not this catalog.
- Add a daemon-private, run-qualified membership journal/checkpoint owned by this projection. Persist membership/terminal transitions before publishing catalog generations, rebuild the complete same-run membership set after a projection crash, reconcile it against the current Orchestrator snapshot, and ignore then clean up the obsolete generation when `run_id` changes. This is recovery state for one run, not a cross-run analytics store.
- Reuse Orchestrator `StatusReport` and tracker lifecycle observations for current lifecycle, allocation, pause, retry and terminal truth. Join BO-005 only for event-derived activity such as stage, progress, freshness and latest safe evidence; do not make TicketActivity a second lifecycle or membership authority.
- Join those sources with Decision counts. Expose typed tracker/repository/issue identity, title and trusted URL, lifecycle, waiting/blocking reason, backend, agent family, requested/resolved model, effort, complexity, optional build lane, progress with source/freshness, latest evidence, runtime timestamps, open Command count, and provider health. Missing data remains unknown.
- Define the single-select scope truth table:
  - `Live`: a worker is allocated or actively retained by the runtime, including working, alerting, Executor-paused, and stuck units;
  - `Unfinished`: `Live` plus queued, dependency-waiting, and retry-waiting units that are not terminal;
  - `All`: every current-run member, including terminal rows;
  - `None`: no rows.
- Define independent, overlapping condition predicates: `Active` means currently executing work; `Alert` means an open Executor/supervisor Command or explicit error attention; `Paused` means authoritative Executor/runtime pause; `Stuck` means unresponsive or backing off beyond the accepted threshold; `Queued` means unfinished without an allocated executing worker; `Finished` means a terminal tracker/runtime outcome observed in this run. Unknown state satisfies none of these predicates.
- Treat current main's runner `work_state: :completed` plus
  `waiting_reason: :awaiting_dispatch` as a nonterminal replacement boundary
  when the tracker remains active. That row is `Unfinished` and `Queued`, but
  not `Live`, `Active`, `Paused`, or `Finished`; it consumes neither active
  capacity nor a worker slot. The atom name must never clear a GitHub blocker
  or imply ticket completion.
- Define filter composition: apply the selected scope first; no selected condition chip means no condition refinement; one or more selected chips use OR within the condition set. A row is visible when it is in scope and matches any selected condition. Predicate counts are calculated over the selected scope before condition refinement, so overlapping counts are allowed and are not presented as a partition.
- Define a versioned URL codec for scope and selected conditions, canonical ordering, unknown-value removal, defaults, and zero-result reset. Expose pure snapshot, lookup, predicate, count, and URL encode/decode APIs; render no LiveView UI here.

## Non-goals

- Render the Units page, add mutation controls, fetch usage/cost meters, implement Commands, or implement the Build Order graph.
- Create a second TicketActivity or Orchestrator lifecycle reducer, infer finished rows from recent PR text, or retain prior-run rows in the current-run view.
- Treat runtime progress as GitHub completion, convert missing values to zero, or make condition counts sum to the catalog total.

## Existing owner and reuse target

Build the current-run membership owner and Units catalog/policy layer over
`Aiur.Orchestrator.StatusReport`/tracker lifecycle facts, BO-005 activity facts,
canonical tracker `Issue` values, and Decision projections. Reuse typed identity
and freshness contracts rather than keying by bare issue number. The catalog's
run-qualified recovery journal is the sole owner of terminal membership
retention; it does not take ownership of Orchestrator lifecycle state.

## Contract and invariants

- `run_id` plus typed issue identity uniquely keys a row. Terminal retention lasts through the current run and does not depend on current AgentList visibility.
- A projection restart in the same run reconstructs the same membership and terminal rows before reporting healthy. A new `run_id` cannot replay prior-run membership into the current catalog.
- StatusReport/tracker facts own lifecycle; BO-005 owns event activity; the catalog composes both and never resolves disagreement by overwriting either source.
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
- Policy and projection tests cover active-tracker
  `:completed/:awaiting_dispatch` before and after replacement, proving the row
  stays visible, counts as queued/unfinished only, and consumes zero active
  capacity.
- Catalog tests cover run transition, retry and fallback, pause/resume, terminal retention, typed-identity collisions, provider failure, stale progress, and no prior-run leakage.
- Recovery/fault tests kill and restart only the catalog process within one BEAM run, then prove queued and terminal membership rebuild exactly. They also cover append/checkpoint failure, torn/corrupt recovery state, snapshot/journal races, and a new-run generation refusing prior-run rows.
- URL/count property tests prove canonical round trips, invalid-value recovery, count/filter parity, and overlapping counts.

### At-merge gate

- Rebase over BO-005 and the resolved configured integration target; run shared activity, AgentList, Orchestrator, Decision, presenter compatibility, private state-directory/recovery, packaging, and full CI suites with no duplicate event subscriptions or row folds.

### Human/manual evidence

- No separate visual evidence. DASH-003 owns the real-dashboard proof against this contract.

## Failure, security, migration, and accessibility cases

- Provider failure preserves last-known-good row facts with health/freshness; it does not remove a current-run member or clear a waiting reason. Unreadable recovery state reports degraded/unavailable membership rather than a healthy truncated catalog.
- Rows and URLs contain no raw workspace path, prompt, transcript, credentials, account identity, capability URL, or environment value.
- Recovery files are owner-only beneath the private daemon state root and contain only versioned run identity, typed ticket identity, membership/lifecycle transition and bounded provenance needed to rebuild; titles, bodies, logs and provider payloads are excluded.
- Run-generation recovery data is private, versioned and bounded to the active run; no historical analytics store is created here.
- Human-readable status/reason strings are part of the projection so consumers do not rely on color or private atoms alone.

## Surfaces

- Reads: BO-005 activity snapshot, Orchestrator `StatusReport`/tracker lifecycle observations, Decision counts, current `run_id`, same-run recovery state.
- Writes: current-run membership journal/checkpoint and catalog projection, pure policy/URL codec, PubSub change events, tests.
- Contracts: `UnitsRow`, current-run membership/retention, scope/condition truth table, count and URL codec APIs.

## Sibling boundaries and open gates

DASH-003 renders this contract and DASH-005 adds authenticated controls. DASH-014 computes aggregate run status without changing row predicates. Build Order may supply optional lane/complexity facts, but this catalog remains usable when those fields are unknown.
