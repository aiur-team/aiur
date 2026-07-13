# DASH-005 — Render unit and capacity controls

**Kind:** executable

**Provenance:** planned in plan v1 after control-plane adversarial review

**Complexity:** 3 — Authenticated command UI over fixed Units and control contracts

**Risk:** high

**Depends on:** DASH-002, DASH-003, DASH-004

**Serializes with:** DASH-003 and other Units/DashboardLive/shared CSS branches

**External gate:** `GATE-OCC-PREDECESSOR-BASELINE` — resolve before dispatch

**Requirements:** DREQ-005

**Researched at:** `1e0cfba31c0e6cc4fea14a25e8b4344ef1d6d67d`

**Suggested labels:** `complexity:3`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Authenticated Executors can pause or resume eligible Units and set a positive max-agent capacity from the Units page, with correlated pending/application feedback, authoritative capacity reconciliation, and no client-forged state.

## Context and evidence

DASH-004 supplies the missing worker-applied lifecycle for unit controls. Current main also exposes `Aiur.Orchestrator.Slots.set_max_concurrent_agents/1`, whose accepted domain is positive integers and whose lowering behavior drains rather than kills workers. The prototype permits zero, pauses arbitrary rows locally, and restores them from browser memory; none of those behaviors can be copied.

## Scope

- Define and render an eligibility matrix for running, applied-paused, pending-control, queued, retrying, merging, terminal, replaced-generation, request-only, unsupported, and Remote Control units. Recheck capability, writable mode, authentication, identity generation, and current state at invocation.
- Invoke pause/resume only through DASH-004. Render requested, accepted, applied, rejected, expired, superseded, and request-only states with retry guidance; do not change the row's authoritative lifecycle before the corresponding contract state.
- Invoke capacity changes through `Aiur.Orchestrator.Slots.set_max_concurrent_agents/1` and reconcile the returned/current authoritative maximum and draining state. The UI minimum is `1`; zero is invalid. Global pause remains the existing workflow control, not a hidden `max agents = 0` behavior.
- Debounce repeated activation while one request is pending, preserve focus after completion/error, and resolve concurrent row changes truthfully. A changed or terminal row cancels stale UI intent rather than targeting a replacement unit.
- Expose pause owner/reason, request state, and capacity draining/failure in accessible text. Keep controls named and reachable at every supported Units breakpoint.

## Non-goals

- Implement the Units catalog/filter UI, change scheduling policy, kill workers to satisfy a lower cap, mutate tracker labels, add start/cancel/reprioritize, or implement Build Order controls.
- Emulate backend controls in JavaScript, restore prior worker state from browser memory, or make zero a valid cap.
- Weaken current Basic Auth, CSRF, same-origin, writable, or capability gates.

## Existing owner and reuse target

Extend DASH-003's Units action seam, consume DASH-004 control lifecycle, and reuse `Aiur.Orchestrator.Slots.set_max_concurrent_agents/1`, endpoint writable state, current authentication pipelines, and existing error normalization.

## Contract and invariants

- Invocation rechecks server-side authorization, writable mode, typed identity/generation, eligibility, and capability; mount-time state is insufficient.
- A unit control displays applied only from DASH-004 evidence. A capacity control displays the authoritative returned/snapshot value, never the requested value alone.
- Max agents is a positive integer. Lowering the cap preserves draining semantics and never chooses/pauses individual units in browser code.
- Duplicate activation is idempotent or disabled while pending. Concurrent completion/generation change wins over stale intent.
- Read-only, unauthenticated, unsupported, and request-only states are visibly distinct and cannot masquerade as enabled applied controls.

## Refreshable implementation notes

- Refresh final DASH-004 capability names and the current slot API response at pickup. The correct runtime function is `set_max_concurrent_agents`, not `set_max_agents` on `Slots`.
- Keep LiveView handlers thin: validate event shape, recheck server state, call the owner, and render normalized result.
- Reuse the current AgentLog control copy/error patterns where compatible, but remove any optimistic-success behavior.

## Acceptance and verification

### Agent gate

- LiveView tests cover every eligibility/capability state, writable/auth changes, double activation, request-only mode, timeout/rejection/application, concurrent terminal/generation change, and focus/error recovery.
- Capacity tests cover valid raise/lower, invalid zero/non-integer/out-of-range input, draining, slot failure, stale snapshot, and authoritative reconciliation.
- Browser/a11y tests cover keyboard/touch, at least 44px targets, explicit names/states/reasons, pending announcements, 200% zoom, and narrow Units layouts.

### At-merge gate

- Rebase on DASH-002/003/004 and the resolved configured integration target, sequence shared dashboard files, and pass control, slot, auth/write-gate, audit, Units, browser accessibility, and full CI suites.

### Human/manual evidence

- From the Executor repository root, run the real authenticated writable dashboard, pause and resume one supported unit through worker-applied confirmation, exercise an unavailable control, then raise and lower the max-agent setting and observe authoritative draining/cap state.

## Failure, security, migration, and accessibility cases

- Network/control/provider failure leaves the last authoritative state visible with a named error and safe retry; it never changes row or cap locally.
- Preserve Basic Auth, CSRF, same-origin, writable, and control authorization. Redact request internals from browser errors and logs.
- No tracker or stored-data migration.
- Controls expose name, current state, pending state, reason, focus, target size, and non-color feedback.

## Surfaces

- Reads: DASH-002 Units rows, DASH-004 capabilities/lifecycle, writable/auth state, authoritative slot capacity.
- Writes: LiveView control handlers, pending/error presentation, capacity requests, components and tests.
- Contracts: Units action eligibility/presentation and positive capacity input.

## Sibling boundaries and open gates

DASH-002 owns row truth, DASH-003 owns filters/layout, and DASH-004 owns control application. This ticket adds no Build Order mutation and must not turn visual controls into a new scheduler.
