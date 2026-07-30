# AS-301 — Server-side dispatch allowlist + provenance

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — see GitHub issue #1359 for the full researched contract

**Risk:** medium

**Phase hint:** 1

**Depends on:** none

**Serializes with:** none

**Requirements:** REQ-009

**Researched at:** 76477691bc3cbc2a2bddd01d5fe4c8c686fffdf1

## Outcome

Dispatch requires an allowlisted issue creator or label applier, verified via the timeline API, failing closed.

## Context and evidence

GitHub issue [#1359](https://github.com/its-everdred/aiur/issues/1359) is the full
worker-ready contract (researched scope, exact file:line pointers, decision
rationale, acceptance checklist). Research pack: `docs/research/` on the
`executor-handoff` branch. This document is the planning-graph record; the
issue body is the implementation contract.

## Scope

- Exactly the scope enumerated in issue #1359; the issue's acceptance
  checklist is the ticket's acceptance boundary.

## Non-goals

- Sibling-ticket behavior as delimited in the issue body and the dependency
  edges above.

## Existing owner and reuse target

Named in issue #1359 (files, modules, and patterns to extend are cited with
file:line references verified at the researched commit).

## Contract and invariants

As specified in issue #1359.

## Refreshable implementation notes

File:line pointers in issue #1359 were verified at commit 76477691; the
worker refreshes them at pickup without silently changing scope.

## Acceptance and verification

### Agent gate

- The acceptance checklist in issue #1359 passes in the issue workspace.

### At-merge gate

- CI green on the current base (mix test --cover >= 85%, lint, dialyzer;
  plus the packages/streamdeck job where applicable).

### Human/manual evidence

- Only where issue #1359 names it (hardware verification, screenshots).

## Failure, security, migration, and accessibility cases

As enumerated in issue #1359; none beyond it.

## Surfaces

- Reads: see issue #1359
- Writes: see issue #1359
- Contracts: see issue #1359

## Sibling boundaries and open gates

Dependency edges above; cliques recorded in build-order.json.
