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

**Researched at:** 1e0cfba31c0e6cc4fea14a25e8b4344ef1d6d67d

**Suggested labels:** `complexity:4`, `model:codex`, `phase:2`, `build-lane:infrastructure`; never `agent:todo`

## Outcome

Aiur's normalized issue, orchestrator status, and runtime events needed by
ticket activity carry one trusted, repository-qualified tracker identity; the
event-derived fields use a versioned observation envelope, so later consumers
can join status and activity to GitHub members without guessing from a bare
ticket number or event topic.

## Context and evidence

Current event topics often contain a display identifier such as
`ticket.<id>`, while repository/project identity lives in issue, workspace, or
run context. A topic is routing text, not authenticated identity. Inferring the
repository from the active directory, current workflow, or a numeric suffix can
cross-wire tickets when repositories share a workspace root or when old events
arrive after a run changes.

The current GitHub REST normalizer receives owner/repository context and a
GitHub `node_id`, but `Aiur.Issue` retains only the display issue number as both
`id` and `identifier`. StatusReport therefore cannot expose the canonical node
identity even though it already owns execution, waiting, backend/model, and
latest-worker status. This ticket retains that existing ownership while making
its records joinable, and establishes trustworthy event identity before BO-005
extracts only the event-derived UI fold.

## Scope

- Define a versioned tracker identity containing tracker kind, GitHub
  owner/repository identity, canonical opaque issue identity, and display
  identifier/number as non-canonical locators. Keep the type extensible, but do
  not implement Linear parity in this ticket.
- Add the identity to the normalized tracker issue contract without changing
  the legacy dispatch meaning of `Issue.id`/`identifier`. Populate GitHub
  identity from the configured owner/repository and the REST/GraphQL node ID
  already returned by ordinary tracker reads; do not add a per-event provider
  fetch.
- Propagate that typed identity through orchestrator running/retrying/idle
  snapshots and existing status PubSub/API records while preserving
  StatusReport as the owner of lifecycle, waiting, backend/model/effort, and
  latest-worker facts.
- Define a versioned event observation envelope with trusted identity,
  run/attempt/session provenance where available, event/source identity,
  occurred and observed timestamps, payload version, and safe typed attributes.
- Attach identity where trusted issue/workspace/run context is created or
  already available, before publication to the shared event path.
- Migrate only the progress, active-agent-stage, and latest safe cross-ticket
  evidence producers BO-005 will consume. Preserve compatibility for unrelated
  subscribers; lifecycle/waiting/backend facts continue through StatusReport
  rather than a duplicate event fold.
- Classify legacy/unqualified events as explicitly unattributed or invalid for
  repository-qualified joins; do not infer identity from `ticket.<number>`,
  basename, current repository, or whichever agent is active.
- Provide total normalization and safe redaction for malformed, duplicate,
  out-of-order, and legacy envelopes.
- Document the compatibility window and producer inventory so later usage
  companions reuse or serialize on this envelope rather than fork identity.

## Non-goals

- Store per-ticket activity state, choose the latest event observation,
  calculate progress, migrate AgentList, perform an additional GitHub fetch, or
  render the dashboard.
- Populate repository-qualified identities for Linear or cross-repository Build
  Orders; unrelated tracker records remain compatible but nonjoinable for this
  GitHub-only feature.
- Put repository identity into an untrusted user-controlled topic and call it
  canonical.
- Require unrelated event consumers to understand Build Order domain records.

## Existing owner and reuse target

Extend `Aiur.Issue`, the current tracker normalizers, StatusReport snapshot
records, event publication/normalization, and issue workspace/run context.
Preserve event topics for subscription routing while placing authoritative
identity in typed records and normalized envelopes.

## Contract and invariants

- A repository-qualified join requires identity supplied by a trusted producer
  context. Bare number, slug-like topic segment, title, and local path are never
  canonical evidence.
- For GitHub, a joinable identity contains configured owner/repository plus the
  provider node ID already present on the normalized issue response. A legacy
  or malformed GitHub issue without node identity remains explicitly
  unjoinable; repository plus number is a locator, not a silent substitute.
- StatusReport remains canonical for execution/waiting/backend facts. Adding
  identity cannot create a second lifecycle projection or change dispatch keys.
- Identity is stable across retry/session changes; run, attempt, and session
  provenance remain separate dimensions.
- `occurred_at` describes source time and `observed_at` ingestion time. Missing
  or invalid time remains explicit rather than becoming now.
- Envelope normalization is total and redacts source content not required by
  the typed activity contract.
- Legacy compatibility cannot silently join an event to a Build Order member.

## Refreshable implementation notes

- Inventory `Aiur.Issue`, GitHub normalization, compatibility call sites in
  other trackers, StatusReport
  snapshots, event structs, PubSub payloads, agent-runner callbacks, workspace
  metadata, and test factories on the configured integration branch before
  choosing the smallest versioned identity/envelope seam.
- Prefer small adapters at producers plus one normalizer rather than parallel
  payload formats per backend.
- Coordinate with any companion usage-envelope work that touches the same
  protocol producers; serialize those edits while reusing this identity.

## Acceptance and verification

### Agent gate

- Tests cover GitHub normalization retaining owner/repository/node identity,
  two repositories with the same issue number, retry/session changes,
  out-of-order observations, malformed timestamps, missing node identity,
  legacy topics, and producer restarts.
- Negative tests prove a bare `ticket.42`, workspace basename, active workflow,
  or display identifier cannot become a repository-qualified join key.
- Status snapshot tests prove running/retrying/idle records carry the same typed
  identity while legacy `Issue.id` dispatch behavior and existing waiting/
  backend/model fields remain compatible.
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

- Reads: configured tracker repository, normalized provider issue responses,
  trusted issue/workspace/run context, StatusReport, and current event producer
  payloads.
- Writes: tracker identity type, `Aiur.Issue`/tracker normalization,
  StatusReport identity propagation, event envelope/normalizer, migrated
  producers, compatibility tests, and producer inventory.
- Contracts: repository-qualified tracker identity; observed event envelope;
  identity-bearing status snapshot; unattributed-event behavior.

## Sibling boundaries and open gates

BO-005 alone owns the event-activity projection and BO-006 owns AgentList
migration. StatusReport retains orchestrator lifecycle ownership.
Usage/accounting companions may reuse the identity/envelope, but are neither
hard prerequisites nor permission to widen this ticket into financial storage.
