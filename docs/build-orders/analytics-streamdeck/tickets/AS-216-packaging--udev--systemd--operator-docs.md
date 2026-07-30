# AS-216 — Packaging: udev, systemd, operator docs

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 2 — see GitHub issue #1357 for the full researched contract

**Risk:** low

**Phase hint:** 5

**Depends on:** AS-213

**Serializes with:** none

**Requirements:** REQ-007

**Researched at:** 76477691bc3cbc2a2bddd01d5fe4c8c686fffdf1

## Outcome

The sidecar installs and survives reboot, suspend, and replug from documented operator steps.

## Context and evidence

GitHub issue [#1357](https://github.com/its-everdred/aiur/issues/1357) is the full
worker-ready contract (researched scope, exact file:line pointers, decision
rationale, acceptance checklist). Research pack: `docs/research/` on the
`executor-handoff` branch. This document is the planning-graph record; the
issue body is the implementation contract.

## Scope

- Exactly the scope enumerated in issue #1357; the issue's acceptance
  checklist is the ticket's acceptance boundary.

## Non-goals

- Sibling-ticket behavior as delimited in the issue body and the dependency
  edges above.

## Existing owner and reuse target

Named in issue #1357 (files, modules, and patterns to extend are cited with
file:line references verified at the researched commit).

## Contract and invariants

As specified in issue #1357.

## Refreshable implementation notes

File:line pointers in issue #1357 were verified at commit 76477691; the
worker refreshes them at pickup without silently changing scope.

## Acceptance and verification

### Agent gate

- The acceptance checklist in issue #1357 passes in the issue workspace.

### At-merge gate

- CI green on the current base (mix test --cover >= 85%, lint, dialyzer;
  plus the packages/streamdeck job where applicable).

### Human/manual evidence

- Only where issue #1357 names it (hardware verification, screenshots).

## Failure, security, migration, and accessibility cases

As enumerated in issue #1357; none beyond it.

## Surfaces

- Reads: see issue #1357
- Writes: see issue #1357
- Contracts: see issue #1357

## Sibling boundaries and open gates

Dependency edges above; cliques recorded in build-order.json.
