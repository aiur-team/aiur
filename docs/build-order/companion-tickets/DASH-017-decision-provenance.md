# DASH-017 — Persist trusted Decision provenance

**Kind:** executable

**Provenance:** planned in plan v1 after companion-boundary review

**Complexity:** 3 — Additive durable schema, trusted runtime capture, validation, and replay migration

**Risk:** high

**Depends on:** none

**Serializes with:** DASH-006 and Decision schema/store/history changes

**External gate:** `GATE-OCC-PREDECESSOR-BASELINE` — resolve before dispatch

**Requirements:** DREQ-017

**Researched at:** `9849f32963c2a65367bce565b3f5ede3777c218f`

**Suggested labels:** `complexity:3`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Every new Decision may retain exact trusted agent/backend/model/session provenance and actor-scoped confidence, while legacy records remain readable with those facts explicitly unknown.

## Context and evidence

The prototype derives provider/model from display prose and shows confidence not present in the canonical schema. Production needs source-backed immutable provenance captured at Decision acceptance, not reconstructed in the Commands UI. Query and pagination work belongs to DASH-006 so this ticket has one durable-schema and migration boundary.

## Scope

- Version Decision provenance to optionally persist agent family, backend, requested model, resolved model, session/attempt identity, source, and captured time.
- Populate provenance only from authoritative runtime/session context at acceptance. Agent payload fields and `originName`, question, rationale, or other prose are never trusted inputs.
- Add optional supervising recommendation/decision confidence as an exact validated decimal in `[0, 1]`, with actor, source, and captured time.
- Allow only the authenticated supervising decision path to author supervisor confidence. Confidence never grants authority or changes lifecycle.
- Preserve provenance/confidence append-only across answer, revision, delivery, acknowledgement, resolution, and history records with the action/version that captured it.
- Add one versioned additive migration/replay path. Legacy records have absent/unknown provenance and confidence; never guess historical values.
- Expose the canonical optional fields to existing presenters/providers without requiring DASH-006 or DASH-007 to infer them.

## Non-goals

- Add lookup/pagination/search/counts, redesign Commands, change Decision authority/lifecycle, infer legacy fields, or persist provider account identity.
- Accept model/backend/confidence from agent-authored content, display strings, prompts, transcripts, or untrusted event payloads.
- Rename the Decision domain or rewrite unrelated store behavior.

## Existing owner and reuse target

Extend `Aiur.Decision`, `DecisionValidation`, `DecisionEvent`, `DecisionProjection`, `DecisionStore`, `DecisionHistory`, and trusted Decision acceptance paths. Reuse schema-versioning, append-only audit, exact-decimal validation, supervisor authentication, and replay conventions.

## Contract and invariants

- Provenance is accepted only from trusted runtime context and is immutable for the Decision version that captured it.
- Confidence is exact, finite, `[0,1]`, actor-scoped, source-backed, and append-only. It cannot alter authority or lifecycle.
- Legacy/human records may be unknown. Unknown is never reconstructed from prose or current session state.
- Revision/history round trips preserve original provenance and confidence independently for every version/action.
- Durable values exclude account/email/org, raw prompt/session payload, credential, and capability material.

## Refreshable implementation notes

- Refresh current Decision schema/event versions and trusted runtime context at pickup. Keep new fields optional through the full replay chain.
- Coordinate shared `DecisionStore` ownership with DASH-006 and active predecessor work; serialize rather than adding a false hard edge.
- Prefer additive structs/validators/serializers under the repository size limits over further expansion of giant modules.

## Acceptance and verification

### Agent gate

- Schema/replay tests cover trusted backend/model fallback, session/attempt capture, legacy unknowns, forged agent/display fields, exact valid/invalid confidence, revisions, delivery/history, and rollback-compatible reads.
- Authority tests prove only authenticated supervising paths author supervisor confidence and confidence cannot change lifecycle or actor authority.
- Security tests prove account/email/org, prompt, transcript, credential, raw session payload, and capability fields cannot enter provenance or logs.

### At-merge gate

- Rebase on the resolved configured integration target and sequence with DASH-006/active Decision work; run Decision schema/store/event/projection/history, supervisor authority, migration/replay, security, and full CI suites.

### Human/manual evidence

- Using synthetic Decisions, show one trusted runtime provenance record, one supervising-confidence record, and one legacy record that remains explicitly unknown after replay.

## Failure, security, migration, and accessibility cases

- Missing trusted context leaves optional facts unknown and does not reject an otherwise valid legacy-compatible Decision.
- Never persist or log account identity, raw prompt/transcript/session payloads, credentials, environment values, or capability URLs.
- Schema/replay and rollback behavior are versioned; no migration manufactures historical fields.
- No direct UI. Optional values and unknown reasons have stable human-readable labels for DASH-007.

## Surfaces

- Reads: authoritative runtime/session context and authenticated supervising action context.
- Writes: Decision schema/event/projection/store/history fields, validation, replay migration, tests.
- Contracts: trusted immutable Decision provenance and actor-scoped confidence.

## Sibling boundaries and open gates

DASH-006 owns retained read/query behavior and DASH-007 owns presentation. Neither may parse prose to replace absent provenance. DASH-006 and DASH-017 serialize on shared Decision modules but can be reviewed and reverted independently.
