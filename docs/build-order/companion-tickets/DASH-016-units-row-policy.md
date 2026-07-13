# DASH-016 — Project canonical Units rows and policy

**Kind:** executable

**Provenance:** planned in plan v1 after companion-boundary review

**Complexity:** 3 — One bounded read model with source-aware joins and a shared filter/URL contract

**Risk:** high

**Phase hint:** 4

**Depends on:** DASH-002, BO-005

**Serializes with:** none

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-016

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:3`, `model:codex`, `phase:4`, `build-lane:dashboard-ui`; never `agent:todo`

**Build Order membership:** member of the consolidated Build Order (operator decision 2026-07-13)

## Outcome

Aiur exposes provenance-rich `UnitsRow` snapshots plus one pure truth table for Live/Unfinished/All/None scope, overlapping Active/Alert/Paused/Stuck/Queued/Finished conditions, counts, and shareable URL state.

## Context and evidence

DASH-002 supplies the recoverable current-run member set. BO-005 owns event-derived ticket activity. Current Fleet presentation mixes lifecycle, activity, and filter policy, while the prototype's exclusive status buckets misclassify multi-signal rows. This ticket composes existing authorities without becoming another lifecycle or persistence owner; DASH-003 renders the result.

## Scope

- Join DASH-002 membership with current StatusReport/tracker lifecycle, BO-005 activity, canonical tracker issue facts, and Decision counts.
- Expose typed tracker/repository/issue identity, trusted title/URL, lifecycle, waiting/blocking/alert reasons, backend, agent family, requested/resolved model, effort, complexity, optional build lane, progress with source/freshness, latest safe evidence, runtime timestamps, open Command count, and provider health. Missing facts remain unknown.
- Define single-select scope:
  - `Live`: a worker is allocated or retained by the runtime, including working, alerting, Executor-paused, and stuck units;
  - `Unfinished`: `Live` plus queued, dependency-waiting, and retry-waiting nonterminal units;
  - `All`: every DASH-002 current-run member, including terminal rows;
  - `None`: no rows.
- Define independent overlapping conditions: `Active`, `Alert`, `Paused`, `Stuck`, `Queued`, and `Finished`. Unknown state satisfies none.
- Treat active-tracker `work_state: :completed` plus `waiting_reason: :awaiting_dispatch` as a nonterminal replacement boundary: `Unfinished` and `Queued`, but not `Live`, `Active`, `Paused`, or `Finished`, consuming no active capacity.
- Apply scope first. No selected condition means no refinement; selected conditions OR together. Calculate chip counts over scope before condition refinement so overlap is explicit.
- Define a versioned URL codec with canonical ordering, defaults, invalid-value removal, and a named zero-result reset.
- Expose pure row lookup, predicate, filter, count, and URL encode/decode APIs plus bounded snapshot health/freshness. Render no UI.

## Non-goals

- Persist membership, reduce activity/lifecycle events, render Units, add controls, fetch usage/meters, or implement Build Order.
- Make counts a partition, turn missing progress into zero, infer model/state from prose, or fetch GitHub/workspace logs during a query.
- Change DASH-002 retention or BO-005 activity semantics.

## Existing owner and reuse target

Build a policy/read-model layer over DASH-002, BO-005, `Aiur.Orchestrator.StatusReport`, canonical `Issue` values, and Decision projections. Keep predicate and URL modules free of LiveView dependencies so dashboard, API, and tests share one truth table.

## Contract and invariants

- DASH-002 owns membership; StatusReport/tracker owns lifecycle; BO-005 owns event activity. A `UnitsRow` preserves provenance instead of overwriting disagreement.
- Counts and filtering call the same pure predicates. Multi-signal rows may satisfy multiple conditions and counts need not sum to scope total.
- Waiting, blocking, alert, and pause reasons remain distinct.
- Optional facts carry source/freshness or are unknown. Unknown progress, lifecycle, model, or health is never rendered downstream as zero, Finished, or healthy.
- URL decoding cannot create a selection the policy API cannot represent.

## Refreshable implementation notes

- Refresh DASH-002/BO-005 snapshot names and current Fleet behavior at pickup; adapt rather than fork either contract.
- Characterize retry, waiting, safe tracker URL, Decision count, and provider-degradation behavior before replacing Fleet policy.
- Keep row construction, predicates, counts, and URL codec as separately tested modules under the repository's size limits.

## Acceptance and verification

### Agent gate

- Join tests cover missing/stale/conflicting source facts, typed-identity collisions, terminal retention, retry/fallback, pause/resume, Decision counts, and provider degradation.
- Pure truth-table tests cover every scope and multi-signal combination, including alert+paused, alert+stuck, queued+dependency-waiting, terminal+stale activity, and wholly unknown rows.
- Replacement-boundary tests prove active-tracker `:completed/:awaiting_dispatch` remains queued/unfinished only and consumes zero capacity.
- Property tests prove URL round trips, invalid recovery, count/filter parity, canonical ordering, zero-result reset, and overlapping counts.

### At-merge gate

- Rebase on DASH-002, BO-005, and the resolved configured integration target; run membership, activity, Orchestrator/StatusReport, Decision, presenter compatibility, property, and full CI suites.

### Human/manual evidence

- No separate visual evidence. DASH-003 owns real-dashboard verification against this truth table.

## Failure, security, migration, and accessibility cases

- A degraded source preserves safe last-known-good facts with health/freshness or makes fields unknown; it does not remove a DASH-002 member or clear a reason.
- Rows contain no raw workspace paths, prompts, transcripts, credentials, account identity, capability URLs, or provider payloads.
- Version row and URL contracts; preserve explicit compatibility for existing Fleet query links or redirects.
- Human-readable status/reason values and count labels do not rely on color or private atoms.

## Surfaces

- Reads: DASH-002 membership, BO-005 activity, StatusReport/tracker facts, Decision counts.
- Writes: `UnitsRow` projection, pure policy/count/URL modules, bounded snapshot change events, tests.
- Contracts: source-aware Units rows, lifecycle/condition truth table, count and URL APIs.

## Sibling boundaries and open gates

DASH-003 renders this contract, DASH-005 invokes controls through its action seam, and DASH-014 aggregates these exact predicates. Build Order may supply optional lane/complexity facts, but Units remains usable when they are unknown.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-016`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
