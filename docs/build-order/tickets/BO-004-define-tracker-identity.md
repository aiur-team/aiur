# BO: BO-004 — Define configured-repository tracker identity

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — Bounded Issue and StatusReport identity foundation for one configured GitHub repository

**Risk:** high

**Phase hint:** 1

**Depends on:** none

**Serializes with:** none

**External gates:** GATE-001 (integration baseline), GATE-002 (Executor skill)

**Requirements:** BOREQ-005

**Decisions:** DEC-001, DEC-013

**Design evidence:** DESIGN-002

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:3`, `model:codex-gpt-5.6-terra`, `phase:1`, `build-lane:plan-graph`; never `agent:todo`

## Outcome

Aiur's normalized `Issue` and `StatusReport` records carry one trusted tracker
identity for the configured GitHub repository, so downstream joins never guess
from a bare issue number, topic, title, workspace, or active workflow.

## Context and evidence

The configured GitHub normalizer receives owner/repository context and a
provider `node_id`, but the dispatch record historically retains the display
number as both `id` and `identifier`. Repositories can share issue numbers, and
runtime state can outlive a workspace/run transition. The identity foundation
must therefore land before Build Order domain records, event propagation,
detail providers, or activity joins.

This ticket owns only the stable `Issue`/`StatusReport` foundation. BO-017 owns
the versioned event envelope and producer propagation; BO-001 imports this
identity rather than defining a duplicate Build Order identity type.

## Scope

- Define a versioned tracker identity containing tracker kind, configured
  owner/repository, canonical opaque provider issue identity, and display
  identifier/number as a non-canonical locator.
- Add the identity to normalized `Issue` without changing the legacy dispatch
  meaning of `Issue.id` or `Issue.identifier`. Populate it from trusted tracker
  configuration plus the provider node identity already returned by GitHub.
- Propagate the exact identity through running/retrying/idle `StatusReport`
  records and existing status PubSub/API snapshots while preserving
  StatusReport ownership of lifecycle, waiting, backend/model, effort, and
  latest-worker facts.
- Restrict the contract to the configured repository. A response, request, or
  legacy record naming another repository is explicitly nonjoinable/rejected;
  it never inherits the configured repository silently.
- Preserve compatibility for other trackers and legacy call sites with an
  explicit absent/unjoinable identity state; do not implement Linear parity.
- Provide total normalization and safe errors for missing/malformed provider
  identity and repository mismatch.

## Non-goals

- Define or migrate event envelopes/producers, fold activity, persist history,
  fetch ticket detail, calculate progress, or render UI.
- Support cross-repository Build Orders, switch repositories at runtime, or
  synthesize identity from a number, title, topic, path, or working directory.
- Change dispatch keys or duplicate StatusReport lifecycle ownership.

## Existing owner and reuse target

Extend `Aiur.Issue`, configured GitHub normalization, tracker configuration,
StatusReport records, and their existing test factories/serialization seams.
Keep repository identity in typed records rather than routing strings.

## Contract and invariants

- A joinable GitHub identity contains tracker kind, the exact configured
  owner/repository, and provider node identity. Number is display/locator only.
- Repository mismatch is explicit and fail-closed; no component substitutes
  the currently active workflow or local workspace repository.
- Identity is stable across retry/session changes; run, attempt, and session
  provenance remain separate future event dimensions.
- StatusReport remains canonical for its existing fields. Adding identity does
  not create a second lifecycle projection or change dispatch behavior.
- Legacy/malformed records stay compatible but nonjoinable and never match a
  Build Order member or detail request accidentally.

## Refreshable implementation notes

- Inventory `Aiur.Issue`, GitHub REST/GraphQL normalization, tracker config,
  StatusReport structs/APIs/PubSub, compatibility trackers, serializers, and
  test factories on the configured integration branch.
- Prefer one small identity type and adapters at existing constructors over
  parallel identity maps in each consumer.
- Coordinate public-shape changes with BO-017, but do not absorb its producer
  migration.

## Acceptance and verification

### Agent gate

- Tests cover configured owner/repository/node identity, two repositories with
  the same number, repository mismatch, missing node identity, malformed input,
  retry/session changes, and legacy nonjoinable records.
- Negative tests prove a bare `ticket.42`, issue number, title, workspace
  basename, current directory, or active workflow cannot become canonical.
- StatusReport tests prove running/retrying/idle records retain exact identity
  while existing lifecycle/waiting/backend/model fields and dispatch keys stay
  compatible.

### At-merge gate

- Tracker normalization, Issue, StatusReport, PubSub/API, compatibility,
  compile/lint/spec, and repository CI pass on the configured integration
  branch.
- BO-001, BO-017, and BO-016 consume this one published identity contract.

### Human/manual evidence

- None separately; BO-015 proves configured-repository identity against the
  published root and runtime state.

## Failure, security, migration, and accessibility cases

- Never include credentials, account identity, prompts, raw model output,
  capability URLs, or local paths in identity/error records.
- This is an in-memory/public-shape compatibility migration; version serialized
  forms where required and keep legacy input explicitly nonjoinable.
- There is no direct UI; safe typed failure reasons must support later concise
  accessible unknown/unavailable messaging.

## Surfaces

- Reads: configured GitHub repository; normalized provider issue responses;
  Issue and StatusReport constructors/snapshots.
- Writes: configured-repository tracker identity; Issue normalization;
  identity-bearing StatusReport and compatibility tests.
- Contracts: configured-repository tracker identity; identity-bearing Issue and
  orchestrator status; explicit unjoinable/mismatch behavior.

## Sibling boundaries and open gates

BO-017 alone owns event-envelope propagation, BO-001 owns Build Order domain
semantics, BO-005 owns current activity, and BO-016 owns ticket detail. GATE-001
and GATE-002 are direct pre-dispatch gates. BO-001 receives them transitively
through this hard dependency rather than duplicating gate ownership.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `BO-004`
- [Graph waves, critical path, and parallelism](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/aiur-team/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
