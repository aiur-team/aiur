# BO-003 — Add a second graph projection

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — Defines one new provider contract

**Risk:** medium

**Phase hint:** 1

**Requirements:** REQ-001

**Researched at:** 0123456789abcdef0123456789abcdef01234567

## Outcome

A second projection is available.

## Context and evidence

This fixture exercises worker-ticket validation.

## Scope

- Add one projection.

## Non-goals

- Change feature acceptance.

## Existing owner and reuse target

Extend the provider boundary.

## Contract and invariants

Preserve the existing snapshot contract.

## Refreshable implementation notes

Refresh paths at pickup.

## Acceptance and verification

### Agent gate

- Provider tests pass.

### At-merge gate

- Current-base integration passes.

### Human/manual evidence

None.

## Failure, security, migration, and accessibility cases

No additional cases apply.

## Surfaces

- Reads: graph projection.
- Writes: second projection.
- Contracts: provider snapshot.

## Sibling boundaries and open gates

The capstone owns final acceptance.
