# BO-005 — Project shared ticket activity

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — New supervised event fold with headless-safe ownership

**Risk:** high

**Phase hint:** 3

**Depends on:** BO-004

**Serializes with:** BO-003

**Requirements:** BOREQ-005, BOREQ-006

**Decisions:** DEC-001, DEC-006

**Design evidence:** DESIGN-001, DESIGN-002

**Researched at:** b7c4e7c06b8c7011f306ce9efb0b9cd8fd8cbac5

**Suggested labels:** `complexity:4`, `model:codex`, `phase:3`, `build-lane:backend`; never `agent:todo`

## Outcome

One always-supervised, headless-safe projection owns normalized per-ticket Aiur
activity and publishes typed snapshots that AgentList, Build Order, and future
read-only consumers can share without parsing logs or depending on a TUI
process.

## Context and evidence

Progress, active CE stage, and latest activity are currently folded inside the
interactive AgentList lifecycle and pruned with its visible roster. Background
runs and dashboard-only consumers cannot treat that UI process as canonical.
BO-004 supplies trustworthy identity; this ticket supplies state ownership and
ordering semantics.

## Scope

- Add an always-supervised projection keyed only by BO-004's trusted
  repository-qualified tracker identity.
- Fold typed execution state, explicit waiting reason, active agent stage,
  progress value/source/time, latest safe evidence, backend/model/effort where
  authoritative, run/attempt/session provenance, and observed time.
- Define per-field ordering/idempotency rules for duplicate, late, cross-attempt,
  reset, completion, retry, and provider-restart observations. Do not let one
  older event roll back an independently newer field.
- Expose bounded snapshot/query and PubSub generation APIs suitable for
  AgentList and LiveView. Publish after state is applied and preserve typed
  identity in every update.
- Retain active/queued/retrying/paused and bounded recently completed activity
  needed by selected Build Order members; make retention/eviction observable.
- Represent absent, stale, unsupported, unattributed, and invalid observations
  explicitly. Open-ticket progress after restart is unknown until trusted new
  evidence arrives; it is not `0%`.
- Extract reusable pure reducers from AgentList where their current behavior is
  intentional, with characterization coverage before ownership moves.

## Non-goals

- Fetch GitHub, decide dependency satisfaction/readiness, store financial usage,
  parse workspace logs in LiveView, or render TUI/dashboard state.
- Migrate AgentList consumers in this ticket; BO-006 owns the cutover and old
  ownership removal.
- Infer repository identity from an event topic, issue number, current run, or
  local path when BO-004 marks the observation unattributed.

## Existing owner and reuse target

Extract the pure activity fold from current AgentList event-intake/state modules
and reuse existing event/PubSub, waiting-reason, run, backend, and progress
vocabulary. The new projection becomes the state owner; AgentList remains a
consumer until BO-006 completes.

## Contract and invariants

- Snapshot identity is the exact trusted tracker identity from BO-004. Display
  IDs are never alternate keys.
- Planned rollout phase and active agent/CE stage remain separate fields.
- Progress is an observation with source, observed time, and freshness; it
  never changes GitHub lifecycle or any edge state.
- Missing/stale activity is unknown. A GitHub outcome may later render a card
  complete, but this projection never fabricates that outcome.
- Projection restart, eviction, and provider failure remain visible and cannot
  synthesize zero, idle, success, or readiness.

## Refreshable implementation notes

- Refresh the current AgentList reducer and application-supervision seams before
  extraction; serialize supervision edits with BO-003.
- Use injected clock/retention policy and deterministic reducer tests rather
  than sleeps.
- Keep normalized evidence concise and redacted; full transcripts/logs stay in
  their existing owners and load only through explicit supported actions.

## Acceptance and verification

### Agent gate

- Reducer tests cover duplicates, out-of-order per-field updates, retries,
  attempts, fallback/backend changes, stage start/end, progress reset,
  completion, restart, stale/unknown, unattributed events, and eviction.
- Two-repository/same-number tests prove no cross-talk; headless-supervision tests
  prove the projection works when AgentList is absent.
- Existing AgentList characterization tests remain green before consumer
  migration and snapshot/PubSub tests contain no sleep-based races.

### At-merge gate

- Event/projection/supervision tests, compile/lint/spec checks, and full CI pass
  on the current configured integration branch.
- Shared supervision changes are reconciled with BO-003 before merge.

### Human/manual evidence

- None separately; BO-015 proves live activity updates through the real CLI and
  dashboard.

## Failure, security, migration, and accessibility cases

- Never retain prompts, raw model output, secrets, credentials, capability
  URLs, account identifiers, or local paths in activity snapshots.
- V1 activity is in-memory; restart and bounded retention behavior are explicit,
  so no persisted migration is introduced.
- Waiting/progress/provider states include concise accessible text for later
  consumers instead of color-only codes.

## Surfaces

- Reads: BO-004 normalized event envelopes; current pure AgentList reducers and
  runtime vocabulary.
- Writes: supervised TicketActivity projection, reducer/query/PubSub APIs,
  retention policy, and tests.
- Contracts: TicketActivity snapshot/update; field ordering and freshness;
  headless/restart semantics.

## Sibling boundaries and open gates

BO-006 migrates AgentList and removes duplicate ownership. BO-007 performs the
GitHub/Aiur join. Usage companions may reuse identity or serialize on shared
event producers, but financial observation/storage is outside this ticket.

