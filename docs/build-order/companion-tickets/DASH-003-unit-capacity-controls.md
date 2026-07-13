# DASH-003 — Add unit and capacity controls

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Authenticated multi-command control reconciliation

**Risk:** high

**Depends on:** DASH-002

**Requirements:** DREQ-003

**Researched at:** 3d67b7be722eb649f28088fc8d609dd7b75254c7

**Suggested labels:** `complexity:4`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Eligible Units rows expose real pause/resume and the page exposes max-agent changes, with capability/auth gating, authoritative confirmation, pending/error recovery, and no optimistic state forgery.

## Context and evidence

`AgentChat.pause/1` and `resume/1` exist, and `Orchestrator.Slots.set_max_agents/1` owns absolute cap/draining behavior. Production currently wires pause only from the agent-log modal. The prototype toggles client objects immediately and cannot be copied.

## Scope

- Define eligible action matrix for running, operator-paused, queued, retrying, merging, finished, Remote Control, unsupported, and concurrently changing units.
- Wire per-unit pause/resume through the authoritative control plane and max-agent changes through the existing slot/cap API.
- Recheck writable/auth/capability at invocation, debounce/idempotently track pending commands, and reconcile only from authoritative snapshot/PubSub changes.
- Surface request ID/pending, timeout, rejection, worker-slot/capacity/draining, concurrent-state, and recovery feedback while preserving pause/waiting reason.
- Provide audit/alert events and accessible names/state for each unit/capacity action.

## Non-goals

- Mutate tracker labels directly, fake row/cap values locally, implement Units filter policy, or change scheduling semantics.
- Add Start/Cancel/reprioritize behavior without a separately accepted contract.

## Existing owner and reuse target

Reuse `Aiur.AgentChat`, its capability API, `Aiur.Orchestrator.Slots.set_max_agents/1`, dashboard writable gating, and Observability PubSub; add thin LiveView command state only.

## Contract and invariants

- A UI command is pending until the control plane confirms or returns a structured failure; double activation is idempotent.
- Read-only/unauthenticated/unsupported states expose reason and cannot dispatch.
- Lowering the cap preserves draining semantics; it never kills workers merely to match the displayed value.
- Concurrent state change wins over stale UI intent and prompts a truthful refresh/error.

## Refreshable implementation notes

- Refresh current control RPC and dynamic writable checks at pickup.
- Keep pause/resume and cap handlers small and share error normalization with existing AgentLog controls.

## Acceptance and verification

### Agent gate

- Tests cover every eligibility state, writable/auth changes, double click, timeout, rejection, concurrent completion, pause reason, resume, cap raise/lower/draining, and worker-slot failure.
- Browser tests cover labels, focus, pending/disabled/error/live confirmation, keyboard/touch, and no client-forged success.

### At-merge gate

- Control, LiveView, max-agent, auth, audit/alert, and full current-base CI pass.

### Human/manual evidence

- Reviewer pauses/resumes one real eligible unit and changes the cap through the authenticated dashboard, observing authoritative state.

## Failure, security, migration, and accessibility cases

- Mutation stays behind existing Basic Auth, same-origin/CSRF/write gates; redact request internals.
- No tracker/data migration.
- Controls have explicit names, states, target sizes, focus, and non-color feedback.

## Surfaces

- Reads: Units row/capability snapshots; dashboard writable state; slot cap state.
- Writes: AgentChat/slot control requests; pending/error UI and audit events.
- Contracts: unit action matrix and authoritative reconciliation.

## Sibling boundaries and open gates

DASH-002 owns rows/filtering. DASH-001 owns shell. This ticket must not alter Build Order or dispatch tickets.

