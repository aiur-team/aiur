# BO-002 — Prove merged feature acceptance

**Kind:** capstone

**Provenance:** planned in plan v1

**Complexity:** 2 — Runs bounded integration and operator checks

**Risk:** medium

**Phase hint:** 2

**Depends on:** BO-001

**Requirements:** REQ-002

**Researched at:** 0123456789abcdef0123456789abcdef01234567

## Outcome

The bounded feature has durable merged-base acceptance evidence.

## Context and evidence

The finite feature boundary requires named merged-base operator evidence.

## Scope

- Run the named integration and operator acceptance workflow.
- Record evidence against current main.

## Non-goals

- Fix deferred reliability or optimization findings.

## Existing owner and reuse target

Reuse the repository's current integration and manual-acceptance harnesses.

## Contract and invariants

This ticket owns feature-level acceptance. It may return a contributing ticket
to rework, but it cannot expand the active feature boundary for non-blockers.

## Refreshable implementation notes

Refresh the current-base test commands and operator workflow at pickup.

## Acceptance and verification

### Agent gate

- The acceptance harness passes in the issue workspace.

### At-merge gate

- The acceptance harness passes on current main.

### Human/manual evidence

- The operator observes the complete Build Order workflow.

## Failure, security, migration, and accessibility cases

Record failed proof without expanding scope; no migration or new input applies.

## Surfaces

- Reads: `BuildOrderSnapshot`.
- Writes: acceptance evidence.
- Contracts: feature acceptance.

## Sibling boundaries and open gates

BO-001 owns the provider contract; this ticket owns only final acceptance.
