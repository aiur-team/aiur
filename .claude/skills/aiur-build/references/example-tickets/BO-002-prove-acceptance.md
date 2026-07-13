# BO-002 — Prove merged feature acceptance

**Kind:** capstone

**Provenance:** planned in plan v1

**Complexity:** 2 — Runs bounded integration and operator checks

**Risk:** medium

**Phase hint:** 2

**Depends on:** BO-001

**Requirements:** REQ-002

## Outcome

The bounded feature has durable merged-base acceptance evidence.

## Scope

- Run the named integration and operator acceptance workflow.
- Record evidence against current main.

## Non-goals

- Fix deferred reliability or optimization findings.

## Contract and invariants

This ticket owns feature-level acceptance. It may return a contributing ticket
to rework, but it cannot expand the active feature boundary for non-blockers.

## Acceptance and verification

### Agent gate

- The acceptance harness passes in the issue workspace.

### At-merge gate

- The acceptance harness passes on current main.

### Human/manual evidence

- The operator observes the complete Build Order workflow.

## Surfaces

- Reads: `BuildOrderSnapshot`.
- Writes: acceptance evidence.
- Contracts: feature acceptance.
