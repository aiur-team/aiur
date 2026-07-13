# BO-017 — Propagate typed ticket event observations

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Cross-producer versioned event-envelope propagation with compatibility and redaction

**Risk:** high

**Phase hint:** 2

**Depends on:** BO-004

**Serializes with:** none

**Requirements:** BOREQ-005, BOREQ-006

**Decisions:** DEC-001, DEC-006

**Design evidence:** DESIGN-001, DESIGN-002

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:4`, `model:codex`, `phase:2`, `build-lane:runtime`; never `agent:todo`

## Outcome

Progress, active-stage, and latest-safe-evidence producers publish one
versioned observation envelope carrying BO-004 configured-repository identity,
source/run provenance, and trustworthy time semantics.

## Context and evidence

Event topics such as `ticket.<id>` are routing text, not authenticated identity.
Inferring repository from the current workflow or workspace can cross-wire the
same issue number across repositories or attach delayed events to a later run.
BO-004 establishes identity at Issue/StatusReport seams; this ticket propagates
it through the event producers that BO-005 and BO-019 consume.

## Scope

- Define a versioned observation envelope with BO-004 identity, source/event
  identity, run/attempt/session provenance where available, occurred and
  observed timestamps, payload version, and bounded safe typed attributes.
- Attach identity at trusted issue/workspace/run producer contexts before
  publication; preserve existing event topics only for subscription routing.
- Migrate progress, active-agent-stage, and latest-safe-cross-ticket-evidence
  producers. Publish a durable producer inventory and compatibility window.
- Classify legacy/unqualified events as unattributed/nonjoinable. Never infer
  repository identity from topic, issue number, path, active workflow, or
  currently selected agent.
- Normalize malformed, duplicate, delayed, and out-of-order observations
  totally, with explicit occurred-versus-observed time and safe redaction.
- Preserve compatibility for unrelated subscribers through adapters rather
  than requiring them to understand Build Order records.

## Non-goals

- Define Issue/StatusReport identity, fold activity state, choose latest
  observations, persist/replay history, parse logs, or render UI.
- Migrate unrelated events, implement Linear parity, or include financial usage.
- Treat user-controlled topics/prose as canonical identity.

## Existing owner and reuse target

Extend current event structs, producer callbacks, workspace/run context,
normalizers, PubSub/event-bus payloads, and compatibility adapters. Reuse
BO-004 identity exactly.

## Contract and invariants

- Only a trusted BO-004 configured-repository identity is joinable. Legacy and
  mismatched-repository observations remain explicit and nonjoinable.
- Identity is stable across attempts; attempt/session/source provenance stays
  separate.
- `occurred_at` is source time and `observed_at` is ingestion time. Invalid or
  absent time remains unknown, never "now."
- Attributes are typed, bounded, and redacted; the envelope never carries raw
  prompts/model output, credentials, logs, account data, or local paths.
- Compatibility adapters cannot silently qualify legacy events.

## Refreshable implementation notes

- Inventory every intended producer and subscriber on the configured
  integration branch before editing public payload shapes.
- Prefer one normalizer plus small producer adapters, not per-backend envelope
  variants.
- Keep this ticket independent of BO-005 reducer/projection ownership.

## Acceptance and verification

### Agent gate

- Tests cover every migrated producer, two repositories sharing a number,
  retry/session changes, duplicates, out-of-order observations, malformed
  timestamps, missing identity, legacy topics, restart, and redaction.
- Negative tests prove number/topic/path/active workflow cannot qualify an
  observation.
- Existing unrelated subscribers and routing topics remain compatible.

### At-merge gate

- Producer, normalizer, event-bus/PubSub, compatibility, compile/lint/spec, and
  repository CI pass on the configured integration branch.
- The producer inventory is complete for BO-005 without log parsing.

### Human/manual evidence

- None separately; BO-015 proves live observations join the correct member.

## Failure, security, migration, and accessibility cases

- Redact credentials, prompts, raw output, private content, capability URLs,
  account identity, and local paths before publication.
- Version the envelope; legacy input remains explicitly nonjoinable and needs
  no persisted rewrite.
- Typed failure/provenance must support concise accessible later rendering.

## Surfaces

- Reads: BO-004 identity; progress/stage/latest-evidence producers; trusted
  issue/workspace/run context.
- Writes: versioned observation envelope/normalizer; producer propagation;
  compatibility adapters/inventory/tests.
- Contracts: configured-repository observation envelope; legacy unattributed
  behavior; occurred/observed time and safe provenance.

## Sibling boundaries and open gates

BO-004 owns Issue/StatusReport identity, BO-005 owns the current activity fold,
and BO-019 owns bounded recent history. Usage companions may reuse this envelope
but cannot widen this ticket into accounting storage.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `BO-017`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
