# BO-004 — Project shared ticket activity

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — New always-supervised reducer across runtime event sources

**Risk:** high

**Phase hint:** 2

**Depends on:** BO-001

**Serializes with:** BO-003

**Requirements:** BOREQ-005, BOREQ-006

**Decisions:** DEC-001, DEC-006

**Design evidence:** DESIGN-002

**Researched at:** 3d67b7be722eb649f28088fc8d609dd7b75254c7

**Suggested labels:** `complexity:4`, `model:codex`, `phase:2`, `build-lane:backend`; never `agent:todo`

## Outcome

Aiur exposes a headless-safe, daemon-owned activity snapshot for every relevant ticket, with typed identity, execution state, progress provenance, stage, backend/model, token counters, latest evidence, and explicit staleness.

## Context and evidence

Runtime facts are currently split between dashboard Presenter payloads, status reports, and the interactive AgentList's `EventIntake`/Roster state. The UI-owned fold prunes records and is unavailable as an authoritative headless dashboard dependency.

This ticket creates the canonical projection only. BO-005 separately migrates AgentList so creation and consumer conversion remain independently reviewable.

## Scope

- Extract or reuse pure reducers for progress, active CE stage, latest evidence, waiting/blocking state, backend/model/effort, tokens, run/session/attempt identity, and observed time.
- Key records by tracker kind plus project/repository identity plus issue identity; never a bare issue number.
- Subscribe to unconditional global debug/event and agent lifecycle sources needed in headless and interactive modes, while avoiding duplicate counting.
- Retain active, queued, retrying, paused, completed, and recently relevant tickets with a bounded retention/eviction policy independent of AgentList visibility.
- Expose snapshot, lookup, health, generation, and PubSub change contracts. Preserve source and freshness for every progress/evidence field.
- Define honest restart semantics: without replay or new observation, open-ticket progress is unknown.

## Non-goals

- Migrate AgentList consumers or remove its compatibility code; BO-005 owns that.
- Fetch GitHub, decide dependency readiness, persist usage accounting, or parse workspace logs in LiveView.
- Turn absent activity into zero progress or prune a member because no agent is currently running.

## Existing owner and reuse target

Start from pure reducers in `Aiur.AgentList.EventIntake`, the global `Aiur.Events.DebugLog` stream, `Aiur.AgentPubSub`, and orchestrator status sources. Build a shared projection rather than teaching `AiurWeb.Presenter` or Build Order to scrape each owner.

## Contract and invariants

- Each field includes source/observed time or is explicitly unknown; stale values remain distinguishable from current values.
- Typed identity prevents collisions across tracker projects/repositories.
- Progress is a runtime observation and never changes GitHub lifecycle or dependency satisfaction.
- Duplicate/out-of-order events are idempotent or ordered by explicit event identity/time policy.
- Retention is bounded but does not inherit the AgentList roster's visibility pruning.

## Refreshable implementation notes

- Likely modules live under `Aiur.TicketActivity`; refresh current event topic names and unconditional/debug-only delivery semantics at pickup.
- Characterize counter/event ordering before extracting; do not copy three subtly different presenter/status payloads.
- This ticket serializes with BO-003 because both add supervised application children and tests.

## Acceptance and verification

### Agent gate

- Pure reducer tests cover duplicate/out-of-order events, progress ratchet/provenance, stage changes, retries, pause/resume, completed/queued tickets, backend fallback, token updates, and typed-identity collisions.
- Process tests cover headless mode, PubSub generation, bounded retention, provider/source failure, restart unknowns, and no dependency on an AgentList process.
- Tests prove missing activity stays unknown and closed GitHub state is not synthesized here.

### At-merge gate

- Focused event/projection tests, existing AgentList tests, supervision tests, and full current-base CI pass.
- Snapshot shape is documented for BO-006 and consumer migration.

### Human/manual evidence

- No separate human evidence; BO-011 owns end-to-end operator proof.

## Failure, security, migration, and accessibility cases

- Security: store numeric/status/evidence summaries only; no prompts, transcripts, credentials, capability URLs, or raw environment values.
- Migration: projection runs alongside the existing AgentList consumer until BO-005.
- Accessibility: no direct UI; retain concise human-readable waiting/evidence fields.

## Surfaces

- Reads: global agent/event streams; orchestrator lifecycle summaries; Build Order typed identity.
- Writes: TicketActivityProjection state and PubSub; projection/reducer tests.
- Contracts: typed activity snapshot; field provenance/staleness; bounded retention.

## Sibling boundaries and open gates

BO-005 owns AgentList migration. BO-006 joins this snapshot with GitHub planning truth. BO-003 only serializes on supervision surfaces.

