# AS-213 — Device transport and lifecycle

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — see GitHub issue #1354 for the full researched contract

**Risk:** high

**Phase hint:** 3

**Depends on:** AS-201, AS-202

**Serializes with:** none

**Requirements:** REQ-007

**Researched at:** 76477691bc3cbc2a2bddd01d5fe4c8c686fffdf1

## Outcome

The sidecar owns a locked, reset-safe, suspend- and hotplug-resilient device handle.

## Context and evidence

GitHub issue [#1354](https://github.com/its-everdred/aiur/issues/1354) is the full
worker-ready contract (researched scope, exact file:line pointers, decision
rationale, acceptance checklist). Research pack: `docs/research/` on the
`executor-handoff` branch. This document is the planning-graph record; the
issue body is the implementation contract.

## Scope

- Exactly the scope enumerated in issue #1354; the issue's acceptance
  checklist is the ticket's acceptance boundary.

## Non-goals

- Sibling-ticket behavior as delimited in the issue body and the dependency
  edges above.

## Existing owner and reuse target

Named in issue #1354 (files, modules, and patterns to extend are cited with
file:line references verified at the researched commit).

## Contract and invariants

As specified in issue #1354.

## Refreshable implementation notes

File:line pointers in issue #1354 were verified at commit 76477691; the
worker refreshes them at pickup without silently changing scope.

## Acceptance and verification

### Agent gate

- The acceptance checklist in issue #1354 passes in the issue workspace.

### At-merge gate

- CI green on the current base (mix test --cover >= 85%, lint, dialyzer;
  plus the packages/streamdeck job where applicable).

### Human/manual evidence

- Only where issue #1354 names it (hardware verification, screenshots).

## Failure, security, migration, and accessibility cases

As enumerated in issue #1354; none beyond it.

## Surfaces

- Reads: see issue #1354
- Writes: see issue #1354
- Contracts: see issue #1354

## Sibling boundaries and open gates

Dependency edges above; cliques recorded in build-order.json.
