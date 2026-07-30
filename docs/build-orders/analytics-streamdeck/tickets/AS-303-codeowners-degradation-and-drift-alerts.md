# AS-303 — CODEOWNERS degradation and drift alerts

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 2 — see GitHub issue #1361 for the full researched contract

**Risk:** low

**Phase hint:** 2

**Depends on:** AS-301

**Serializes with:** none

**Requirements:** REQ-009

**Researched at:** 76477691bc3cbc2a2bddd01d5fe4c8c686fffdf1

## Outcome

CODEOWNERS failure or allowlist drift raises needs-attention alerts and the trust set is operator-visible.

## Context and evidence

GitHub issue [#1361](https://github.com/its-everdred/aiur/issues/1361) is the full
worker-ready contract (researched scope, exact file:line pointers, decision
rationale, acceptance checklist). Research pack: `docs/research/` on the
`executor-handoff` branch. This document is the planning-graph record; the
issue body is the implementation contract.

## Scope

- Exactly the scope enumerated in issue #1361; the issue's acceptance
  checklist is the ticket's acceptance boundary.

## Non-goals

- Sibling-ticket behavior as delimited in the issue body and the dependency
  edges above.

## Existing owner and reuse target

Named in issue #1361 (files, modules, and patterns to extend are cited with
file:line references verified at the researched commit).

## Contract and invariants

As specified in issue #1361.

## Refreshable implementation notes

File:line pointers in issue #1361 were verified at commit 76477691; the
worker refreshes them at pickup without silently changing scope.

## Acceptance and verification

### Agent gate

- The acceptance checklist in issue #1361 passes in the issue workspace.

### At-merge gate

- CI green on the current base (mix test --cover >= 85%, lint, dialyzer;
  plus the packages/streamdeck job where applicable).

### Human/manual evidence

- Only where issue #1361 names it (hardware verification, screenshots).

## Failure, security, migration, and accessibility cases

As enumerated in issue #1361; none beyond it.

## Surfaces

- Reads: see issue #1361
- Writes: see issue #1361
- Contracts: see issue #1361

## Sibling boundaries and open gates

Dependency edges above; cliques recorded in build-order.json.
