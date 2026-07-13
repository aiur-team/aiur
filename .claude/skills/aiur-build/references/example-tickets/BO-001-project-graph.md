# BO-001 — Project the planning graph

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — Defines one new provider contract

**Risk:** medium

**Phase hint:** 1

**Requirements:** REQ-001

**Researched at:** 0123456789abcdef0123456789abcdef01234567

## Outcome

The dashboard receives one validated planning-graph projection.

## Context and evidence

DESIGN-001 and DEC-001 define the provider's explicit unknown-state behavior.

## Scope

- Define and populate the provider projection.
- Preserve explicit stale, partial-failure, and unknown states.

## Non-goals

- Render the graph.
- Edit GitHub dependencies.

## Existing owner and reuse target

Extend the existing dashboard provider boundary.

## Contract and invariants

GitHub owns materialized ticket facts. Provider failure retains last-known-good
data with visible freshness; it never converts unknown dependencies to empty.

## Refreshable implementation notes

Refresh likely module paths against the ticket pickup commit.

## Acceptance and verification

### Agent gate

- Provider tests cover complete, stale, and failed snapshots.

### At-merge gate

- Current-base integration tests pass.

### Human/manual evidence

None; BO-002 owns feature-level operator evidence.

## Failure, security, migration, and accessibility cases

Provider failure and stale data are explicit; no migration or new input applies.

## Surfaces

- Reads: GitHub issues.
- Writes: Build Order provider.
- Contracts: `BuildOrderSnapshot`.

## Sibling boundaries and open gates

BO-002 owns merged-base feature acceptance; GATE-001 owns interaction approval.
