# DASH-005 — Render applied unit controls

**Kind:** executable

**Provenance:** planned in plan v1 after control-plane adversarial review

**Complexity:** 3 — Authenticated command UI over fixed Units and control contracts

**Risk:** high

**Depends on:** DASH-003, DASH-004

**Serializes with:** DASH-007, DASH-015, DASH-021, DASH-022, DASH-027, DASH-028, DASH-031, DASH-034 — shared `DashboardLive`/CSS

**Predecessor baseline:** resolved — `origin/main` at `9849f32963c2a65367bce565b3f5ede3777c218f`

**Requirements:** DREQ-005

**Researched at:** `9849f32963c2a65367bce565b3f5ede3777c218f`

**Suggested labels:** `complexity:3`, `model:codex`; never `agent:todo`

**Build Order membership:** none — standalone dashboard companion

## Outcome

Authenticated Executors can pause or resume eligible Units from the Units page
with correlated pending/application feedback and no client-forged state.

## Context and evidence

DASH-004 supplies the missing worker-applied lifecycle for unit controls. The
prototype pauses arbitrary rows locally and restores them from browser memory;
that behavior cannot be copied. Runtime capacity has a different owner and
failure model and is isolated in DASH-028.

## Scope

- Define and render an eligibility matrix for running, applied-paused, pending-control, queued, retrying, merging, terminal, replaced-generation, request-only, unsupported, and Remote Control units. Recheck capability, writable mode, authentication, identity generation, and current state at invocation.
- Invoke pause/resume only through DASH-004. Render requested, accepted, applied, rejected, expired, superseded, and request-only states with retry guidance; do not change the row's authoritative lifecycle before the corresponding contract state.
- Debounce repeated activation while one request is pending, preserve focus after completion/error, and resolve concurrent row changes truthfully. A changed or terminal row cancels stale UI intent rather than targeting a replacement unit.
- Expose pause owner/reason and request state in accessible text. Keep controls
  named and reachable at every supported Units breakpoint.

## Non-goals

- Implement the Units catalog/filter UI, runtime-capacity control, change
  scheduling policy, mutate tracker labels, add start/cancel/reprioritize, or
  implement Build Order controls.
- Emulate backend controls in JavaScript or restore prior worker state from
  browser memory.
- Weaken current Basic Auth, CSRF, same-origin, writable, or capability gates.

## Existing owner and reuse target

Extend DASH-003's Units action seam, consume DASH-004 control lifecycle, and
reuse endpoint writable state, current authentication pipelines, and existing
error normalization.

## Contract and invariants

- Invocation rechecks server-side authorization, writable mode, typed identity/generation, eligibility, and capability; mount-time state is insufficient.
- A unit control displays applied only from DASH-004 evidence, never from the
  requested value or a client-local row mutation.
- Duplicate activation is idempotent or disabled while pending. Concurrent completion/generation change wins over stale intent.
- Read-only, unauthenticated, unsupported, and request-only states are visibly distinct and cannot masquerade as enabled applied controls.

## Refreshable implementation notes

- Refresh final DASH-004 capability names and current AgentChat/control seams at
  pickup.
- Keep LiveView handlers thin: validate event shape, recheck server state, call the owner, and render normalized result.
- Reuse the current AgentLog control copy/error patterns where compatible, but remove any optimistic-success behavior.

## Acceptance and verification

### Agent gate

- LiveView tests cover every eligibility/capability state, writable/auth changes, double activation, request-only mode, timeout/rejection/application, concurrent terminal/generation change, and focus/error recovery.
- Browser/a11y tests cover keyboard/touch, at least 44px targets, explicit names/states/reasons, pending announcements, 200% zoom, and narrow Units layouts.

### At-merge gate

- Rebase on DASH-003/004 and the resolved configured integration target,
  sequence shared dashboard files, and pass control, auth/write-gate, audit,
  Units, browser accessibility, and full CI suites.

### Human/manual evidence

- From the Executor repository root, run the real authenticated writable
  dashboard, pause and resume one supported unit through worker-applied
  confirmation, and exercise request-only, unavailable, and concurrent terminal
  states.

## Failure, security, migration, and accessibility cases

- Network/control/provider failure leaves the last authoritative state visible
  with a named error and safe retry; it never changes the row locally.
- Preserve Basic Auth, CSRF, same-origin, writable, and control authorization. Redact request internals from browser errors and logs.
- No tracker or stored-data migration.
- Controls expose name, current state, pending state, reason, focus, target size, and non-color feedback.

## Surfaces

- Reads: DASH-016 Units rows through DASH-003's action seam, DASH-004
  capabilities/lifecycle, and writable/auth state.
- Writes: LiveView unit-control handlers, pending/error presentation,
  components, and tests.
- Contracts: Units pause/resume eligibility and applied-state presentation.

## Sibling boundaries and open gates

DASH-016 owns row truth, DASH-003 owns filters/layout, DASH-004 owns control
application, and DASH-028 alone owns runtime capacity presentation. This ticket
adds no Build Order mutation and must not turn visual controls into a new
scheduler.
