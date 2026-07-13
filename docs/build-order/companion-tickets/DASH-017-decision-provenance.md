# DASH-017 — Persist trusted Decision provenance

**Kind:** executable

**Provenance:** planned in plan v1 after current-schema correction

**Complexity:** 3 — Additive trusted provenance schema, capture, replay, and legacy migration

**Risk:** high

**Depends on:** none

**Serializes with:** DASH-006 — shared Decision schema/store/history surfaces

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-017

**Researched at:** `9849f32963c2a65367bce565b3f5ede3777c218f`

**Suggested labels:** `complexity:3`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Every new Decision may retain exact trusted agent/backend/model/session provenance while legacy records remain readable with those facts explicitly unknown; the existing integer `supervisor_basis.confidence` contract remains unchanged.

## Context and evidence

The prototype derives provider/model from display prose, but production needs source-backed provenance captured at Decision acceptance. Current Aiur already owns supervising confidence in `DecisionDelegation.basis` as integer `0..100`, persisted under `supervisor_basis.confidence` with existing authority, answer, revision, and history semantics. This ticket fills only the missing provenance schema/migration and must not invent or renormalize a second confidence field.

## Scope

- Version Decision provenance to optionally persist agent family, backend, requested model, resolved model, session/attempt identity, source, and captured time.
- Populate provenance only from authoritative runtime/session context at acceptance. Agent payload fields and `originName`, question, rationale, or other prose are never trusted inputs.
- Preserve provenance append-only across answer, revision, delivery, acknowledgement, resolution, and history records with the Decision version that captured it.
- Add one additive migration/replay path. Legacy records have absent/unknown provenance; never guess historical values.
- Preserve the current `DecisionDelegation.basis` and `DecisionAnswer.supervisor_basis` structures unchanged, including integer confidence in `0..100`, policy basis, alternatives, and reversibility fields.
- Expose canonical optional provenance plus the already-existing supervisor basis to DASH-006/007 without introducing another confidence representation.

## Non-goals

- Add lookup/pagination/search/counts, redesign Commands, change Decision authority/lifecycle, or infer legacy provenance.
- Change confidence type, range, scale, validation, authorship, authority, persistence, or presentation meaning; convert it to `[0,1]`; or add recommendation/decision confidence siblings.
- Accept provenance from agent-authored content, display strings, prompts, transcripts, or untrusted event payloads.

## Existing owner and reuse target

Extend `Aiur.Decision`, `DecisionValidation`, `DecisionEvent`, `DecisionProjection`, `DecisionStore`, `DecisionHistory`, and trusted Decision acceptance paths. Reuse schema-versioning, append-only audit, supervisor authentication, and replay conventions. Reuse `DecisionDelegation.basis` exactly for confidence.

## Contract and invariants

- Provenance is accepted only from trusted runtime context and is immutable for the Decision version that captured it.
- Legacy/human records may have unknown provenance. Unknown is never reconstructed from prose or current session state.
- Existing `supervisor_basis.confidence` remains an integer `0..100`; it is neither migrated nor normalized and continues to carry its current actor/authority semantics.
- Revision/history round trips preserve both provenance and the existing supervisor basis independently.
- Durable values exclude account/email/org, raw prompt/session payload, credential, and capability material.

## Refreshable implementation notes

- Refresh current Decision schema/event versions and trusted runtime context at pickup. Keep new provenance fields optional through the full replay chain.
- Characterize `DecisionDelegation`, `DecisionAnswer`, revision, API, and history confidence fixtures before editing, then preserve them byte/semantic-equivalently.
- Coordinate shared `DecisionStore` ownership with DASH-006; serialize rather than adding a false hard edge.

## Acceptance and verification

### Agent gate

- Schema/replay tests cover trusted backend/model fallback, session/attempt capture, legacy unknowns, forged agent/display fields, revisions, delivery/history, and rollback-compatible reads.
- Regression tests cover confidence `0`, `100`, and representative existing values through delegation, answer, revision, API, store, replay, and history, proving no range/type/key/authority change.
- Security tests prove account/email/org, prompt, transcript, credential, raw session payload, and capability fields cannot enter provenance or logs.

### At-merge gate

- Rebase on the resolved configured integration target and sequence with DASH-006/active Decision work; run Decision schema/store/event/projection/history, delegation/answer/API confidence regressions, migration/replay, security, and full CI suites.

### Human/manual evidence

- Using synthetic Decisions, show trusted runtime provenance, a legacy record with unknown provenance, and an existing `supervisor_basis.confidence` value rendered unchanged by DASH-007.

## Failure, security, migration, and accessibility cases

- Missing trusted context leaves optional provenance unknown and does not reject an otherwise valid Decision.
- Never persist or log account identity, raw prompt/transcript/session payloads, credentials, environment values, or capability URLs.
- Version provenance replay/rollback only; no migration manufactures history or rewrites supervisor basis.
- No direct UI. Optional provenance and unknown reasons have stable human-readable labels; confidence retains existing accessible `0..100` meaning.

## Surfaces

- Reads: authoritative runtime/session context; existing Decision and supervisor-basis records.
- Writes: Decision provenance schema/event/projection/store/history fields, validation, replay migration, tests.
- Contracts: trusted immutable Decision provenance; unchanged existing `supervisor_basis.confidence`.
- Safety: Decision audit compatibility, supervisor authority, provenance redaction.

## Sibling boundaries and open gates

DASH-006 owns retained read/query behavior and DASH-007 owns presentation. Neither may parse prose to replace absent provenance. DASH-006 and DASH-017 serialize on shared Decision modules but remain independently reviewable.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-017`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
