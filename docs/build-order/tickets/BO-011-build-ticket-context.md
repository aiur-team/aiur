# BO-011 — Build reusable all-state ticket context

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Shared cached context, dependency navigation, focus lifecycle, and safe cross-surface navigation

**Risk:** high

**Phase hint:** 4

**Depends on:** BO-003, BO-007, BO-008

**Serializes with:** none

**Requirements:** BOREQ-011

**Decisions:** DEC-008, DEC-009

**Design evidence:** DESIGN-001

**Researched at:** 1e0cfba31c0e6cc4fea14a25e8b4344ef1d6d67d

**Suggested labels:** `complexity:4`, `model:codex`, `phase:4`, `build-lane:frontend`; never `agent:todo`

## Outcome

Operators can open one reusable, accessible context surface for running,
queued, paused, completed, invalid, external, or unavailable tickets using only
cached normalized snapshots, navigate both dependency directions, and follow
safe links into existing GitHub, chat, Commands, or control surfaces without
invoking a mutating action from Build Order.

## Context and evidence

The current agent-log modal is optimized for running entries and may perform
lookups inappropriate for every graph card. Build Order cards must remain
body-free and bounded at 100 members, while selected context needs richer
description, dependency, provider, runtime evidence, and safe destination state. The prototype
hard-codes repository links and drops external/missing endpoints.

Read-only v1 forbids GitHub planning mutations and keeps mutating Aiur actions
out of Build Order. Existing chat, Commands, and Units/control surfaces retain
their own contracts; this context may navigate to them without claiming their
actions or acknowledgements.

## Scope

- Define a pure context presenter and reusable component over BO-007's selected
  cached context, BO-003 selected-detail snapshot, upstream/downstream
  adjacency, provider health, activity, and safe destination capabilities.
  Opening/rendering performs no provider, filesystem, or process lookup.
- Keep graph cards body-free; render full title/description and richer facts
  only for the selected cached context, with bounded text and explicit
  missing/partial/stale states.
- Show canonical safe GitHub navigation, lifecycle, complexity/phase/lane,
  edge/readiness state, progress provenance, latest safe evidence, and both
  `Blocked by` and `Blocking` groups including external/missing/cyclic/
  terminal-unsatisfied diagnostics.
- Support in-context replacement navigation among cached endpoints with stable
  history/back behavior, heading focus on replacement, and focus restoration to
  the originating card when closed.
- Request selected detail through BO-003's bounded demand API on selection and
  render its loading/available/partial/stale/unavailable states. Root/member
  changes invalidate stale selection generations; no direct provider call or
  all-member body hydration occurs.
- Render only validated safe links to GitHub and existing chat, Commands, or
  control routes when their destination capability exists. Navigation is not
  evidence that an action succeeded.
- Expose no handler for GitHub membership, label, phase, lane, lifecycle, or
  dependency mutations.

## Non-goals

- Fetch a missing issue/body directly from LiveView or synchronously during
  render, own provider/activity caches, edit GitHub planning state, or replace
  the full interactive chat surface.
- Put issue bodies or mutation payloads into every card/worker/layout message.
- Send chat/commands, answer/retry/revise Decisions, pause/resume a unit, change
  capacity, or expose any other mutating handler from Build Order v1.

## Existing owner and reuse target

Extract reusable presentation/navigation seams alongside current Operator
Control Center detail/agent-log components. Reuse read-only `Aiur.AgentLog`,
safe chat/Decision route links, dashboard authentication, and trusted GitHub
URL policy without copying mutation handlers.

## Contract and invariants

- Context render accepts normalized cached data only and performs no network,
  filesystem, log, or process call.
- Cards remain body-free; selected context content is bounded and never enters
  BO-010's geometry worker.
- Relationship direction, edge state, and member readiness are separate named
  fields and use BO-007 truth unchanged.
- GitHub/planning behavior is read-only. Safe route availability is based on
  normalized destination capability and checked again by the destination
  surface. This component has no mutation event handler.
- Dialog labelling, focus trap, Escape/close, replacement navigation, and origin
  focus restoration are deterministic across LiveView patches.

## Refreshable implementation notes

- Refresh current dashboard detail/action components and the latest authenticated
  mutation safeguards on the configured integration branch before extracting.
- Use BO-003's selected-detail demand/cache contract exactly; do not widen the
  body-free graph payload or add a second cache in LiveView.
- Keep destination links small and typed; do not duplicate scheduler,
  Decision, control, or agent-chat state.

## Acceptance and verification

### Agent gate

- Presenter/component tests cover every member lifecycle, invalid/external/
  missing endpoint, all five edge states, partial/stale providers, body-free
  cards, bounded selected content, safe/unsafe links, and destination capability
  combinations.
- BO-008 browser tests cover mouse, Enter/Space, touch, focus trap, Escape,
  dependency replacement/back, LiveView patch, focus move/restore, and
  screen-reader relationship/status text.
- Selection tests cover coalesced detail demand, loading/stale/unavailable
  detail, root/member generation changes, and no all-member body hydration.
- Security tests prove safe destination links and the absence of GitHub,
  Decision, chat, pause/resume, capacity, or other mutation handlers.

### At-merge gate

- Shared component, existing detail/log/chat/route-link, auth/security,
  accessibility, compile/lint/spec, and full CI pass on the current configured
  integration branch.
- Any Units companion adopting context reuses this contract and serializes on
  shared components instead of forking it.

### Human/manual evidence

- Reviewer uses keyboard only to inspect a running, completed, invalid, and
  external ticket; follows both dependency directions; and follows one safe
  destination link. BO-015 owns final proof.

## Failure, security, migration, and accessibility cases

- Validate safe GitHub links; sanitize descriptions; redact local paths,
  credentials, capability URLs, raw logs, provider errors, and account data.
- Do not change existing runtime action contracts; no stored-data migration is
  introduced.
- Use semantic dialog/headings/lists/buttons, named pending/error states,
  minimum touch targets, non-color status, and deterministic focus restoration.

## Surfaces

- Reads: BO-003 selected-detail snapshots; BO-007 selected cached context and
  adjacency; safe destination capabilities; existing auth state.
- Writes: reusable context presenter/components, selected-detail demand,
  navigation/focus state, safe destination links, and tests.
- Contracts: body-free card versus on-demand selected-context boundary;
  dependency navigation; safe cross-surface destination model.

## Sibling boundaries and open gates

BO-003 owns selected-detail caching, BO-007 owns normalized truth, and BO-012
wires card selection. A Units companion may reuse this component but must
serialize shared UI edits and owns any action extension through DASH-004/005.
