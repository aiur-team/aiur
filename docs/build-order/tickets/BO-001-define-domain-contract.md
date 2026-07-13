# BO-001 — Define Build Order domain contract

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — One new strict domain contract and parser boundary

**Risk:** high

**Phase hint:** 1

**Depends on:** none

**Serializes with:** none

**Requirements:** BOREQ-001, BOREQ-002, BOREQ-003

**Decisions:** DEC-001, DEC-002, DEC-003, DEC-004, DEC-010

**Design evidence:** DESIGN-002

**Researched at:** 3d67b7be722eb649f28088fc8d609dd7b75254c7

**Suggested labels:** `complexity:3`, `model:codex`, `phase:1`, `build-lane:backend`; never `agent:todo`

## Outcome

Aiur has a strict, pure Build Order domain contract that can represent valid, invalid, incomplete, and terminal GitHub planning state without consulting GitHub, Aiur runtime processes, or the dashboard.

## Context and evidence

The current `Aiur.Issue` record is dispatch-oriented and does not retain the GitHub node/database identities, parenthood, state reason, strict planning metadata, or graph diagnostics this feature needs. `Aiur.CodingAgent.complexity_level/1` also deliberately accepts multiple complexity labels and selects the highest; Build Order must reject ambiguity instead.

This ticket is the contract gate for all provider, projection, presenter, layout, and route work. It turns the source-of-truth decisions into types and pure policies before parallel tickets create competing representations.

## Scope

- Define root, member, typed tracker identity, native dependency reference, provider-health, metadata-warning, lifecycle-outcome, and readiness records.
- Parse exactly one `complexity:1..5`, one positive `phase:N`, and one controlled `build-lane:*`; return Unphased/Unassigned/unknown plus diagnostics for missing or duplicate values.
- Parse the bounded hidden logical-ID/provenance marker without treating an absent or malformed optional marker as an invalid GitHub issue.
- Validate that a root has `build-order`, is not itself a sub-issue, and has at most 100 direct members; preserve sub-issue order separately from graph topology.
- Define status precedence: GitHub terminal outcome, runtime overlay, dependency readiness, then planned metadata. Define completed, not-planned, open, unknown, and cyclic edge satisfaction.
- Define external URL and body-marker size/shape bounds and representative pure fixtures.

## Non-goals

- Call GitHub, poll, cache generations, supervise a process, or render UI.
- Define pricing, usage accounting, dashboard dependency editing, Linear, cross-repository membership, or nested Build Orders.
- Reuse dispatch label precedence where strict planning validation is required.

## Existing owner and reuse target

Extend the GitHub identity and label vocabulary around `Aiur.Issue`, `Aiur.GitHub.IssueState`, and `Aiur.GitHub.Labels`, but keep Build Order records in their own bounded namespace. Reuse structured error conventions; do not mutate the general dispatch record merely to fit the dashboard.

## Contract and invariants

- The browser-visible selector uses repository plus mutable issue number; internal joins and cache keys use GitHub node ID plus repository identity.
- Phase is a positive authored hint, not readiness. A dependent may share a phase with its blocker but may not be assigned an earlier phase in the planning baseline.
- Only `CLOSED + COMPLETED` satisfies a blocker. `NOT_PLANNED`, missing, stale, self-loop, or cyclic relationships never become cleared.
- Malformed metadata produces a usable member with warnings whenever GitHub identity and ticket facts remain trustworthy.
- All parsers are total over untrusted GitHub strings and impose explicit input bounds.

## Refreshable implementation notes

- Likely new modules belong under `src/lib/aiur/build_order/`; refresh naming after current-base inspection.
- Use focused fixtures rather than parsing the prototype's illustrative JavaScript dataset.
- Keep public functions small and fully specified per `CONTRIBUTING.md`.

## Acceptance and verification

### Agent gate

- Pure tests cover valid labels, every missing/duplicate/malformed label case, arbitrary positive phases, optional/malformed markers, root-with-parent rejection, member limit, state reasons, self-loops, cycles, and external references.
- Property or table tests prove parsers never raise on bounded arbitrary label/body input.

### At-merge gate

- Compile, format, lint/spec, focused tests, and the repository CI gate pass on the current integration branch.
- Downstream ticket contract names are reconciled against the merged modules before dependent work starts.

### Human/manual evidence

- No separate human evidence; BO-011 owns end-to-end operator proof.

## Failure, security, migration, and accessibility cases

- Security: accept only allowlisted lane values, safe GitHub HTTPS URLs for the configured host/repository policy, and bounded hidden JSON; never render or log raw credentials.
- Migration: no stored schema migration is introduced; this is a new read model.
- Accessibility: no direct UI, but diagnostics and full untruncated titles must remain available to later presenters.

## Surfaces

- Reads: Aiur issue and GitHub label/state contracts; captured feature constraints.
- Writes: Build Order domain records and pure parsers; domain fixtures/tests.
- Contracts: BuildOrder root/member/identity records; metadata and lifecycle policies; readiness vocabulary.

## Sibling boundaries and open gates

BO-002 owns external fetching. BO-006 owns the joined presentation model. BO-009 owns URL routing. Product questions about same-repository/read-only scope are recorded as an external gate; this ticket implements the approved v1 default without expanding it.

