# BO-008 — Build reusable ticket context

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — Shared all-state ticket detail component and interaction contract

**Risk:** medium

**Phase hint:** 4

**Depends on:** BO-006

**Serializes with:** none

**Requirements:** BOREQ-011

**Decisions:** DEC-009

**Design evidence:** DESIGN-001

**Researched at:** 3d67b7be722eb649f28088fc8d609dd7b75254c7

**Suggested labels:** `complexity:3`, `model:codex`, `phase:4`, `build-lane:frontend`; never `agent:todo`

## Outcome

Operators can open one reusable, accessible ticket-context surface for running, queued, completed, invalid, or external Build Order tickets and navigate canonical GitHub and dependency context without triggering new provider reads.

## Context and evidence

The existing agent-log modal only opens currently running entries. `Aiur.IssueContext.for/1` performs synchronous tracker-candidate lookup and cannot safely supply closed Build Order members.

The refreshed prototype adds `Open in GitHub` plus `Blocked by` and `Blocking` chips, but hard-codes the repository and silently drops non-fleet endpoints. Production must consume already-fetched normalized context and explain partial/external relationships.

## Scope

- Create a pure presenter/component contract over an already-fetched member, joined activity, upstream/downstream adjacency, provider health, and available actions.
- Show full identifier/title/description, lifecycle, complexity/phase/lane, dependency state, progress provenance, latest evidence, canonical safe GitHub link, and optional chat/command/log actions.
- Render navigable `Blocked by` and `Blocking` groups including external, missing, stale, and unsatisfied diagnostics; do not color direction itself as success.
- Support in-surface ticket replacement with a clear history/back behavior, move focus to the replacement heading, and restore focus to the originating card on close.
- Provide loading, partial, unavailable, unsafe-URL, missing-log, and unsupported-action states without performing fetches from render.
- Preserve existing operator chat/control safety when actions are available and hide or explain unavailable actions truthfully.

## Non-goals

- Fetch candidates synchronously, own GitHub/Aiur projections, edit dependencies, or decide graph layout.
- Replace the rich interactive chat panel or expose raw workspace paths/log content by default.
- Hard-code repository URLs or assume every relationship endpoint is a visible member.

## Existing owner and reuse target

Extract a shared ticket-context component/presenter alongside the current dashboard `AgentLogModal`, reusing `Aiur.AgentLog`, `Aiur.AgentChat`, canonical Decision links, and the Fleet table's trusted GitHub URL policy where compatible. Do not make the existing running-only modal the data owner.

## Contract and invariants

- Inputs are normalized values from BO-006; component render performs no network/filesystem call.
- External URLs must pass the configured trusted GitHub policy and open safely; unavailable/unsafe links are not rendered as working.
- Relationship direction and satisfaction are separate accessible text fields.
- Dialog supports labelled heading/description, focus trap, Escape, close control, replacement navigation, and origin focus restoration.
- Actions reflect current capability and writable state at invocation, not only mount-time assumptions.

## Refreshable implementation notes

- Likely create small Phoenix components and presenter helpers rather than extending the already-large LiveView render function.
- Refresh in-flight shell/Units/Commands work before editing shared CSS or route helpers.
- Keep log/chat loading optional and event-driven so Build Order cards for completed tickets remain cheap.

## Acceptance and verification

### Agent gate

- Component/LiveView tests cover every ticket lifecycle, safe/unsafe/missing GitHub URL, both dependency directions, external/missing endpoints, partial provider state, action availability, and replacement navigation.
- Browser tests cover mouse, Enter/Space, touch, focus trap, dependency-chip navigation, focus move/restore, Escape, and screen-reader relationship/status text.
- Tests prove opening context does not call GitHub or parse a workspace log unless an explicit supported log action requests it.

### At-merge gate

- Shared component, existing AgentLog/Decision behavior, accessibility, and current-base CI pass after rebasing over dashboard work.
- One ownership note prevents Units and Build Order from forking separate ticket-detail contracts.

### Human/manual evidence

- Reviewer verifies a running member, completed member, and external blocker context with keyboard only.

## Failure, security, migration, and accessibility cases

- Security: redact filesystem/credential/capability data and validate external links.
- Migration: preserve existing AgentLog modal behavior until Units explicitly adopts the shared surface.
- Accessibility: all dialog, relationship, loading/error, and action states are named and keyboard/touch reachable.

## Surfaces

- Reads: BuildOrderViewModel member/context; optional AgentLog and AgentChat capability; canonical Decision/GitHub links.
- Writes: shared ticket-context presenter/components; modal interaction tests.
- Contracts: TicketContext input/action model; dependency navigation/focus behavior; trusted action availability.

## Sibling boundaries and open gates

BO-006 owns normalized context. BO-009 wires it to cards. Units may adopt it later but is not a Build Order dependency. Coordinate DashboardLive/component/CSS ownership with companion branches before pickup.

