# DASH-028 — Render runtime capacity control

**Kind:** executable

**Provenance:** planned in plan v1 after shipped-dashboard capacity-source audit

**Complexity:** 2 — Authenticated presentation over an existing authoritative Orchestrator capacity contract

**Risk:** medium

**Phase hint:** 7

**Depends on:** DASH-003

**Serializes with:** DASH-005, DASH-007, DASH-015, DASH-021, DASH-022, DASH-027, DASH-031, DASH-034 — shared `DashboardLive` and responsive CSS

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-028

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:2`, `model:codex-gpt-5.6-terra`, `phase:7`, `build-lane:dashboard-ui`; never `agent:todo`

**Build Order membership:** member of the consolidated Build Order (operator decision 2026-07-13)

## Outcome

Authenticated Executors can raise or lower the positive runtime max-agent
capacity from Units and see the authoritative active, maximum, session-
override, and draining result without browser code pausing workers or claiming
that a requested value has already applied.

## Context and evidence

Current main already exposes `Aiur.Orchestrator.Slots.max_concurrent_agents/0`,
`adjust_max_concurrent_agents/1`, and `set_max_concurrent_agents/1`. Mutations
serialize inside the Orchestrator and return the current authoritative status;
the accepted domain is positive integers and lowering drains rather than kills
or pauses workers. The prototype instead mutates a client-side cap and pauses/
resumes rows to satisfy it. This ticket renders the production contract; it
does not create a second scheduler or expand the backend without evidence.

## Scope

- Render current `active`, `max`, configured/source/session-override, and
  `draining?` facts returned by the existing Slots/StatusReport contract. If a
  supported fact is absent, label it unknown rather than deriving it from
  rendered rows.
- Provide named decrement/increment controls and, where retained by product
  layout, a validated positive-integer absolute input. The UI minimum is `1`;
  zero never means global pause.
- Recheck Basic Auth, writable mode, same-origin/CSRF policy, current capacity,
  and control capability on every invocation. Mount-time authorization is not
  sufficient.
- Invoke only the Orchestrator-owned adjust/set functions. Disable or debounce
  repeated activation while pending and reconcile from the returned or next
  authoritative snapshot, never the requested value alone.
- Render pending, applied/no-op, invalid, timeout, unavailable, stale response,
  concurrent change, and draining states with bounded accessible copy and safe
  retry guidance.
- Preserve focus and current value across LiveView updates. Coalesce status
  announcements and keep controls named, at least 44px, and usable at all Units
  breakpoints and 200% zoom.
- Preserve the existing precedence and dispatch behavior. Lowering capacity
  stops new dispatch according to Slots policy and never selects, pauses,
  resumes, interrupts, or kills an individual unit.

## Non-goals

- Implement per-unit pause/resume, change Slots precedence/dispatch/worker-host
  policy, add capacity zero, globally pause the workflow, or persist a browser
  value across daemon restart.
- Compute authoritative capacity from visible rows, emulate control in
  JavaScript, mutate tracker labels, or add Build Order controls.
- Add an unauthenticated mutation endpoint or expose configuration secrets.

## Existing owner and reuse target

Extend DASH-003's Units composition and reuse `Aiur.Orchestrator.Slots`, the
existing Orchestrator call handlers, StatusReport/observability updates,
dashboard auth/write gates, and current normalized control errors. Add a thin
presenter only where the existing status map needs stable accessible labels.

## Contract and invariants

- The Orchestrator-returned/current snapshot is authoritative. A client request
  and dashboard-local row count are never proof of application.
- Capacity is a positive integer. Global pause and per-unit pause are separate
  controls with separate owners.
- Lowering capacity preserves draining semantics and never changes unit pause
  ownership or lifecycle in browser code.
- Duplicate/pending controls are idempotent or disabled. A later authoritative
  concurrent change wins over stale UI intent.
- Read-only, unauthorized, invalid, unavailable, pending, applied, and draining
  states are visibly and programmatically distinct.

## Refreshable implementation notes

- Reinspect the exact `max_concurrent_agent_status/1`, adjust/set return map,
  StatusReport projection, and dashboard event names at pickup. Do not invent a
  revision field or parallel store unless current code has changed and a
  separately reviewed contract requires it.
- Keep handlers thin: validate event shape, recheck server authority, call
  Slots, and render the normalized result.
- Coordinate shared Units controls/CSS with DASH-005 and other declared peers.

## Acceptance and verification

### Agent gate

- LiveView tests cover valid increment/decrement/set, minimum `1`, invalid/
  overflow input, no-op, double activation, auth/write-mode changes, timeout/
  unavailable, concurrent returned/status updates, and focus/error recovery.
- Integration tests prove the displayed applied value comes from Slots,
  lowering shows authoritative draining, no unit pause/resume action fires, and
  reconnect restores daemon state rather than browser state.
- Browser/a11y tests cover names, states, pending announcements, keyboard/
  touch, 44px targets, 200% zoom, and 320/390/768/960/desktop reflow.

### At-merge gate

- Rebase on DASH-003 and current main, sequence shared dashboard files, and
  pass Slots, StatusReport, auth/write-gate, Units, browser accessibility, and
  full CI suites.

### Human/manual evidence

- From the Executor repository root, run the real authenticated writable
  dashboard, raise and lower the max-agent setting, observe the authoritative
  active/max/draining state and queued dispatch behavior, then confirm read-only
  mode exposes no usable mutation control.

## Failure, security, migration, and accessibility cases

- Timeout/unavailability leaves the last authoritative state visibly stale or
  unknown with safe retry; it never displays the requested value as applied.
- Preserve Basic Auth, CSRF, same-origin, writable, and Orchestrator authority.
  Browser errors/logs contain no process state, hosts, credentials, or env.
- No stored migration. Session override/restart behavior remains the existing
  Slots contract. All facts/actions are named and non-color-dependent.

## Surfaces

- Reads: authoritative Slots/StatusReport capacity and dashboard auth/write
  state through DASH-003 composition.
- Writes: LiveView capacity handlers/presenter, pending/error presentation,
  responsive components, and tests.
- Contracts: positive capacity input and requested-versus-authoritative result
  presentation.
- Safety: no client-side scheduling or per-unit pause side effects.

## Sibling boundaries and open gates

DASH-005 owns worker-confirmed per-unit pause/resume and DASH-004 owns that
protocol. This ticket owns only global capacity presentation over the existing
Slots contract. It adds no Build Order mutation.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `DASH-028`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
