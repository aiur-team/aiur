# BO-004 — Define typed tracker identity and event envelope

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Cross-producer repository-qualified identity and event-envelope migration

**Risk:** high

**Phase hint:** 2

**Depends on:** BO-001

**Serializes with:** none

**Requirements:** BOREQ-005

**Decisions:** DEC-001, DEC-006

**Design evidence:** DESIGN-002

**Researched at:** b7c4e7c06b8c7011f306ce9efb0b9cd8fd8cbac5

**Suggested labels:** `complexity:4`, `model:codex`, `phase:2`, `build-lane:infrastructure`; never `agent:todo`

## Outcome

Aiur runtime events needed by ticket activity carry one trusted,
repository-qualified tracker identity and a versioned observation envelope, so
later projections can join activity to GitHub members without guessing from a
bare ticket number or event topic.

## Context and evidence

Current event topics often contain a display identifier such as
`ticket.<id>`, while repository/project identity lives in issue, workspace, or
run context. A topic is routing text, not authenticated identity. Inferring the
repository from the active directory, current workflow, or a numeric suffix can
cross-wire tickets when repositories share a workspace root or when old events
arrive after a run changes.

This ticket establishes trustworthy identity at the producer boundary before
BO-005 creates durable process ownership. It does not implement the activity
fold itself.

## Scope

- Define a versioned tracker identity containing tracker kind, provider/project
  or GitHub owner/repository identity, canonical opaque issue identity when
  available, and display identifier/number as non-canonical locators.
- Define a versioned event observation envelope with trusted identity,
  run/attempt/session provenance where available, event/source identity,
  occurred and observed timestamps, payload version, and safe typed attributes.
- Attach identity where trusted issue/workspace/run context is created or
  already available, before publication to the shared event path.
- Migrate the progress, active-agent-stage, latest-evidence, execution/waiting,
  and lifecycle event producers BO-005 will consume. Preserve compatibility for
  unrelated subscribers.
- Classify legacy/unqualified events as explicitly unattributed or invalid for
  repository-qualified joins; do not infer identity from `ticket.<number>`,
  basename, current repository, or whichever agent is active.
- Provide total normalization and safe redaction for malformed, duplicate,
  out-of-order, and legacy envelopes.
- Document the compatibility window and producer inventory so later usage
  companions reuse or serialize on this envelope rather than fork identity.

## Non-goals

- Store per-ticket state, choose the latest observation, calculate progress,
  migrate AgentList, fetch GitHub, or render the dashboard.
- Put repository identity into an untrusted user-controlled topic and call it
  canonical.
- Require unrelated event consumers to understand Build Order domain records.

## Existing owner and reuse target

Extend the current event publication/normalization path, issue workspace/run
context, and typed tracker identity conventions. Preserve event topics for
subscription routing while placing authoritative identity in the normalized
envelope.

## Contract and invariants

- A repository-qualified join requires identity supplied by a trusted producer
  context. Bare number, slug-like topic segment, title, and local path are never
  canonical evidence.
- Identity is stable across retry/session changes; run, attempt, and session
  provenance remain separate dimensions.
- `occurred_at` describes source time and `observed_at` ingestion time. Missing
  or invalid time remains explicit rather than becoming now.
- Envelope normalization is total and redacts source content not required by
  the typed activity contract.
- Legacy compatibility cannot silently join an event to a Build Order member.

## Refreshable implementation notes

- Inventory the current event structs, PubSub payloads, agent-runner callbacks,
  workspace metadata, and test factories on the configured integration branch
  before choosing the smallest versioned envelope seam.
- Prefer small adapters at producers plus one normalizer rather than parallel
  payload formats per backend.
- Coordinate with any companion usage-envelope work that touches the same
  protocol producers; serialize those edits while reusing this identity.

## Acceptance and verification

### Agent gate

- Tests cover two repositories with the same issue number, retry/session
  changes, provider/project identities, out-of-order observations, malformed
  timestamps, missing node identity, legacy topics, and producer restarts.
- Negative tests prove a bare `ticket.42`, workspace basename, active workflow,
  or display identifier cannot become a repository-qualified join key.
- Existing unrelated event subscribers and routing topics remain compatible.

### At-merge gate

- Producer/normalizer/event-bus tests, compile/lint/spec checks, and full CI pass
  on the current configured integration branch.
- The migrated producer inventory is complete enough for BO-005 to consume
  without parsing logs or inventing identity.

### Human/manual evidence

- None separately; BO-015 proves live events join the correct published member.

## Failure, security, migration, and accessibility cases

- Never place credentials, account identity, prompts, raw model output,
  capability URLs, or local paths in the normalized envelope.
- Version the envelope and accept legacy input only through an explicit
  non-joinable compatibility path; no persisted event rewrite is required.
- There is no direct UI, but typed failure reasons must be suitable for later
  accessible unknown/unavailable messaging.

## Surfaces

- Reads: trusted issue/workspace/run context; current event producer payloads.
- Writes: tracker identity type, event envelope/normalizer, migrated producers,
  compatibility tests, and producer inventory.
- Contracts: repository-qualified tracker identity; observed event envelope;
  unattributed-event behavior.

## Sibling boundaries and open gates

BO-005 alone owns the activity projection and BO-006 owns AgentList migration.
Usage/accounting companions may reuse the identity/envelope, but are neither
hard prerequisites nor permission to widen this ticket into financial storage.
