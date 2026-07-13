# DASH-014 — Project canonical run summary

**Kind:** executable

**Provenance:** planned in plan v1 after prototype-summary and runtime-source review

**Complexity:** 4 — Weighted progress and ETA semantics over live, stale, and changing run membership

**Risk:** high

**Depends on:** DASH-016

**Serializes with:** none

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-014

**Researched at:** `9849f32963c2a65367bce565b3f5ede3777c218f`

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Aiur exposes one current-run summary with canonical live and remaining counts, complexity-weighted progress and coverage, wall-clock elapsed time, and a conservative formula-versioned ETA that becomes unavailable rather than invented when evidence is insufficient.

## Context and evidence

The prototype shows live units, remaining tickets, a progress bar, elapsed time, and ETA. Current `agent_totals.seconds_running` is cumulative agent runtime, not run wall time, and no canonical denominator or ETA owner exists. DASH-016 supplies the current-run universe and source-backed row states; this ticket owns the aggregate math without changing those rows.

## Scope

- Define current-run identity from the active `run_id` and persist/capture a canonical wall-clock `started_at` plus monotonic origin for live elapsed calculation. `elapsed_wall_seconds` is time since run start, including pauses; it is never the sum of agent runtimes.
- Compute `live_count` from DASH-016 `Live`, and `remaining_count` as nonterminal current-run members in `Unfinished`. Report terminal successful, terminal non-work/cancelled, unknown-state, and total member counts separately.
- Define progress weight as validated complexity points `1..5`; a member without complexity uses weight `1` and increments `defaulted_weight_count`. Exclude explicitly cancelled/not-planned non-work outcomes from the denominator and report their excluded weight/count.
- Define per-member progress: successful terminal outcome is `1.0`; known queued/not-started is `0.0`; fresh source-backed runtime progress is clamped to `[0,1]`; stale/missing/contradictory progress is unknown. The denominator includes eligible member weight. Return known weighted numerator, unknown-progress weight, lower-bound progress, and coverage. Emit a single exact percentage only when unknown-progress weight is zero; never treat unknown as zero.
- Define ETA formula version `completed_weight_rate_v1`: after at least two successful terminal members, ten wall-clock minutes, a nonzero eligible denominator, and healthy membership/weight facts, compute completed throughput as successful terminal weight divided by wall elapsed and ETA as remaining eligible weight divided by that throughput. Return formula version, sample/completed weight, denominator generation, observation time, and confidence/availability reason. Do not fold partial runtime progress into throughput.
- Recompute on catalog membership/lifecycle/progress changes and run transition. Membership changes update denominator generation and are visible provenance, not silently rewritten history.
- Expose snapshot, health, freshness, generation, and PubSub update APIs. Preserve prior last-known-good aggregate as stale only within the same run generation.

## Non-goals

- Aggregate tokens/cost/quota, infer Build Order critical path, forecast from model intuition, use agent-runtime seconds as elapsed, change ticket progress, or render UI.
- Treat phase as a gate, cancelled/not-planned work as successful completion, or hide defaulted/unknown weights and progress.
- Carry a prior run's ETA/progress into a new run generation.

## Existing owner and reuse target

Build a pure projection over DASH-016's catalog plus `Aiur.Boot` run identity/start metadata and existing progress provenance. Reuse injected clock, PubSub generation, and health patterns.

## Contract and invariants

- Counts call DASH-016 predicates; this projection cannot redefine Live, Unfinished, or terminal membership.
- Wall elapsed derives from run start and never aggregates concurrent worker time. A restart/new `run_id` resets the current-run summary.
- Progress always carries denominator, weight policy, unknown/defaulted/excluded coverage, and generation. Unknown progress is not a zero contribution in an exact percentage.
- ETA is absent until every formula precondition is met and carries formula/version/input provenance when present. No stale prior-run ETA survives generation change.
- Membership/complexity changes are observable denominator changes; clients can explain a percentage movement without agent work.

## Refreshable implementation notes

- Refresh BO/DASH progress field names and Boot run-start availability at pickup. If current run start is not retained centrally, add it to the existing run owner rather than deriving from first browser mount.
- Keep formulas pure and use injected wall/monotonic clocks. Use exact decimal/rational math until final display rounding.
- Document why the conservative ETA ignores partial active progress; alternative estimators are deferred experiments, not silent replacements.

## Acceptance and verification

### Agent gate

- Pure tests cover live/remaining/terminal counts, complexity/default weights, cancelled exclusion, known/unknown/stale progress, denominator changes, run transition, clock movement, and exact weighted reconciliation.
- ETA tests cover every precondition, two-completion threshold, zero/changed denominator, pause-inclusive wall time, membership change, provider degradation, and deterministic formula/provenance output.
- Process tests cover PubSub coalescing, last-known-good within one generation, no prior-run leakage, and headless mode.

### At-merge gate

- Rebase on DASH-016 and the resolved configured integration target; run Units catalog, run lifecycle/Boot, progress, clock, projection/PubSub, regression, and full CI suites.

### Human/manual evidence

- Using a synthetic real run from the Executor repository root, compare wall elapsed with concurrent agent runtime, complete enough weighted tickets to enable ETA, and demonstrate ETA/percentage becoming explicitly unavailable when progress or membership evidence is incomplete.

## Failure, security, migration, and accessibility cases

- Missing run start/catalog/provider evidence produces partial/unavailable with a reason; it never falls back to first browser mount, summed agent time, zero progress, or a guessed ETA.
- Projection stores only run/ticket numeric/status aggregates and no content, account facts, credentials, or workspace paths.
- Version formula and summary schema so future estimator changes do not rewrite the meaning of historical snapshots.
- No direct UI; every count, denominator, coverage, elapsed, and ETA field has a human-readable label/reason for DASH-015.

## Surfaces

- Reads: DASH-016 current-run Units rows/predicates, canonical run identity/start, progress/complexity provenance.
- Writes: current-run summary projection, formula/version metadata, health/freshness/generation, PubSub and tests.
- Contracts: count definitions, weighted progress/coverage, wall elapsed, conservative ETA formula.

## Sibling boundaries and open gates

DASH-022 renders this summary. DASH-011 separately aggregates run/build usage and money, and DASH-015 renders protected provider usage. Build Order readiness/critical-path calculations remain outside this current-run estimator.
