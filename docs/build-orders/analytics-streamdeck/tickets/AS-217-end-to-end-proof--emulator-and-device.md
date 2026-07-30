# AS-217 — End-to-end proof: emulator and device

**Kind:** capstone

**Provenance:** planned in plan v1

**Complexity:** 2 — see GitHub issue #1358 for the full researched contract

**Risk:** medium

**Phase hint:** 6

**Depends on:** AS-203, AS-205, AS-208, AS-210, AS-212, AS-214, AS-215, AS-216, AS-103, AS-104, AS-105, AS-302, AS-303, AS-304

**Serializes with:** none

**Requirements:** REQ-008

**Researched at:** 76477691bc3cbc2a2bddd01d5fe4c8c686fffdf1

## Outcome

Every emulator and device workflow step is evidenced against live fleet state.

## Context and evidence

GitHub issue [#1358](https://github.com/its-everdred/aiur/issues/1358) is the full
worker-ready contract (researched scope, exact file:line pointers, decision
rationale, acceptance checklist). Research pack: `docs/research/` on the
`executor-handoff` branch. This document is the planning-graph record; the
issue body is the implementation contract.

## Scope

- Exactly the scope enumerated in issue #1358; the issue's acceptance
  checklist is the ticket's acceptance boundary.

## Non-goals

- Sibling-ticket behavior as delimited in the issue body and the dependency
  edges above.

## Existing owner and reuse target

Named in issue #1358 (files, modules, and patterns to extend are cited with
file:line references verified at the researched commit).

## Contract and invariants

As specified in issue #1358.

## Refreshable implementation notes

File:line pointers in issue #1358 were verified at commit 76477691; the
worker refreshes them at pickup without silently changing scope.

## Acceptance and verification

### Agent gate

- The acceptance checklist in issue #1358 passes in the issue workspace.

### At-merge gate

- CI green on the current base (mix test --cover >= 85%, lint, dialyzer;
  plus the packages/streamdeck job where applicable).

### Human/manual evidence

- Only where issue #1358 names it (hardware verification, screenshots).

## Failure, security, migration, and accessibility cases

As enumerated in issue #1358; none beyond it.

## Surfaces

- Reads: see issue #1358
- Writes: see issue #1358
- Contracts: see issue #1358

## Sibling boundaries and open gates

Dependency edges above; cliques recorded in build-order.json.
