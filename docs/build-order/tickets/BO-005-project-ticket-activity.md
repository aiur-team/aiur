# BO-005 — Project shared ticket activity

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — New supervised event fold with headless-safe ownership

**Risk:** high

**Phase hint:** 3

**Depends on:** BO-017

**Serializes with:** BO-003, BO-016, DASH-002, DASH-009, DASH-012, DASH-018, DASH-019, DASH-024, DASH-025, DASH-026, DASH-029 — application supervision tree and observation-envelope consumption

**Requirements:** BOREQ-005, BOREQ-006

**Decisions:** DEC-001, DEC-006

**Design evidence:** DESIGN-001, DESIGN-002

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:4`, `model:codex-gpt-5.6-sol`, `phase:3`, `build-lane:runtime`; never `agent:todo`

## Outcome

One always-supervised, headless-safe projection owns normalized per-ticket Aiur
event activity—progress, active agent stage, and latest safe cross-ticket
evidence—and publishes typed snapshots that AgentList, Build Order, and future
read-only consumers can share without parsing logs or depending on a TUI
process. Existing orchestrator StatusReport remains the owner of execution,
waiting, backend/model, and worker-lifecycle state.

## Context and evidence

Progress, active CE stage, and latest activity are currently folded inside the
interactive AgentList lifecycle and pruned with its visible roster. Background
runs and dashboard-only consumers cannot treat that UI process as canonical.
BO-004 supplies configured-repository identity and BO-017 propagates it through
typed observations; this ticket supplies state ownership and ordering semantics
for those event-derived fields. It deliberately extends,
rather than duplicates, StatusReport, which already reports running, retrying,
idle, waiting reason, backend/model, and latest worker observations.

## Scope

- Add an always-supervised projection keyed only by the BO-004 identity carried
  in BO-017 observations.
- Fold active agent stage, progress value/source/time, latest safe cross-ticket
  evidence, run/attempt/session provenance where present, and observed time.
- Define per-field ordering/idempotency rules for duplicate, late, cross-attempt,
  reset, completion, retry, and provider-restart observations. Do not let one
  older event roll back an independently newer field.
- Expose bounded snapshot/query and PubSub generation APIs suitable for
  AgentList and LiveView. Publish after state is applied and preserve typed
  identity in every update.
- Retain bounded event activity for current tracked identities plus bounded
  recently removed identities; make retention/eviction observable. Full
  current-run membership and terminal-row retention belong to the sibling
  DASH-002 catalog, not this event projection.
- Represent absent, stale, unsupported, unattributed, and invalid observations
  explicitly. Open-ticket progress after restart is unknown until trusted new
  evidence arrives; it is not `0%`.
- Extract reusable pure reducers from AgentList where their current behavior is
  intentional, with characterization coverage before ownership moves.

## Non-goals

- Fetch GitHub, decide dependency satisfaction/readiness, own execution/
  waiting/backend lifecycle already supplied by StatusReport, store financial
  usage, parse workspace logs in LiveView, or render TUI/dashboard state.
- Migrate AgentList consumers in this ticket; BO-006 owns the cutover and old
  ownership removal.
- Infer repository identity from an event topic, issue number, current run, or
  local path when BO-017 marks the observation unattributed.

## Existing owner and reuse target

Extract the progress/stage/latest-event fold from current AgentList event-intake
and state modules and reuse existing event/PubSub and progress vocabulary. The
new projection becomes the owner of those event-derived fields; StatusReport
continues owning orchestrator status, and AgentList remains a consumer of both
until BO-006 completes.

## Contract and invariants

- Snapshot identity is the exact trusted tracker identity from BO-017/BO-004. Display
  IDs are never alternate keys.
- Planned rollout phase and active agent/CE stage remain separate fields.
- Progress is a BO-017 observation with source, observed time, and freshness; it
  never changes GitHub lifecycle or any edge state.
- Execution, queue/retry/paused state, waiting reason, backend/model/effort, and
  latest worker status are read from BO-004-identified StatusReport snapshots,
  not mirrored into this projection.
- Missing/stale activity is unknown. A GitHub outcome may later render a card
  complete, but this projection never fabricates that outcome.
- Projection restart, eviction, and provider failure remain visible and cannot
  synthesize zero, idle, success, or readiness.

## Refreshable implementation notes

- Refresh the current AgentList reducer and application-supervision seams before
  extraction; serialize supervision edits with BO-003 and BO-016.
- Use injected clock/retention policy and deterministic reducer tests rather
  than sleeps.
- Keep normalized evidence concise and redacted; full transcripts/logs stay in
  their existing owners and load only through explicit supported actions.

## Acceptance and verification

### Agent gate

- Reducer tests cover duplicates, out-of-order per-field updates, attempts,
  stage start/end, progress reset, completion observations, restart,
  stale/unknown, unattributed events, and eviction.
- Two-repository/same-number tests prove no cross-talk; headless-supervision tests
  prove the projection works when AgentList is absent.
- Contract tests prove execution/waiting/backend fields are not copied or
  independently folded and that consumers can join the separately owned
  StatusReport and event-activity snapshots by BO-004 identity.
- Existing AgentList characterization tests remain green before consumer
  migration and snapshot/PubSub tests contain no sleep-based races.

### At-merge gate

- Event/projection/supervision tests, compile/lint/spec checks, and full CI pass
  on the current configured integration branch.
- Shared supervision changes are reconciled with BO-003 and BO-016 before
  overlapping branches merge.

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

- Reads: BO-017 normalized event envelopes and current pure AgentList
  progress/stage/latest-event reducers.
- Writes: supervised TicketActivity projection, reducer/query/PubSub APIs,
  retention policy, and tests.
- Contracts: event-derived TicketActivity snapshot/update; field ordering and
  freshness; headless/restart semantics; non-ownership of StatusReport fields.

## Sibling boundaries and open gates

BO-004 owns identity, BO-017 owns envelope/producer propagation, BO-006
migrates AgentList, BO-019 owns bounded recent history, and BO-007 performs the
GitHub/Aiur join. BO-003 and BO-016 share only the application supervision tree
with this ticket and therefore serialize rather than gaining data dependencies.
Usage members may reuse identity or serialize on shared event producers, but
financial observation/storage is outside this ticket. DASH-008 and BO-005
declare their symmetric `serializes_with` edge directly in the consolidated
manifest.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `BO-005`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
