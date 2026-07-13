# BO-001 — Project the planning graph

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — Defines one new provider contract

**Risk:** medium

**Phase hint:** 1

**Requirements:** REQ-001

## Outcome

The dashboard receives one validated planning-graph projection.

## Scope

- Define and populate the provider projection.
- Preserve explicit stale, partial-failure, and unknown states.

## Non-goals

- Render the graph.
- Edit GitHub dependencies.

## Contract and invariants

GitHub owns materialized ticket facts. Provider failure retains last-known-good
data with visible freshness; it never converts unknown dependencies to empty.

## Acceptance and verification

### Agent gate

- Provider tests cover complete, stale, and failed snapshots.

### At-merge gate

- Current-base integration tests pass.

### Human/manual evidence

None; BO-002 owns feature-level operator evidence.

## Surfaces

- Reads: GitHub issues.
- Writes: Build Order provider.
- Contracts: `BuildOrderSnapshot`.
