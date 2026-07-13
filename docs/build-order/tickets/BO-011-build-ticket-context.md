# BO-011 — Build reusable all-state ticket context

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Shared cached context, dependency navigation, focus lifecycle, and gated runtime actions

**Risk:** high

**Phase hint:** 4

**Depends on:** BO-007

**Serializes with:** none

**Requirements:** BOREQ-011

**Decisions:** DEC-008, DEC-009

**Design evidence:** DESIGN-001

**Researched at:** b7c4e7c06b8c7011f306ce9efb0b9cd8fd8cbac5

**Suggested labels:** `complexity:4`, `model:codex`, `phase:4`, `build-lane:frontend`; never `agent:todo`

## Outcome

Operators can open one reusable, accessible context surface for running,
queued, paused, completed, invalid, external, or unavailable tickets using only
cached normalized snapshots, navigate both dependency directions, and invoke
existing supported Aiur runtime actions through authoritative capability and
confirmation gates.

## Context and evidence

The current agent-log modal is optimized for running entries and may perform
lookups inappropriate for every graph card. Build Order cards must remain
body-free and bounded at 100 members, while selected context needs richer
description, dependency, provider, and runtime-action state. The prototype
hard-codes repository links and drops external/missing endpoints.

Read-only v1 forbids GitHub planning mutations. It does not remove existing
Aiur chat/log/command/pause capabilities when the dashboard is authenticated,
writable, and the selected ticket supports them.

## Scope

- Define a pure context presenter and reusable component over BO-007's selected
  cached context, upstream/downstream adjacency, provider health, activity, and
  normalized action capabilities. Opening/rendering performs no provider,
  filesystem, or process lookup.
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
- Route existing supported Aiur runtime actions (for example chat/log/command or
  pause/resume) through current capability, Basic Auth, writable, CSRF,
  confirmation, request-correlation, pending, authoritative-result, and error
  boundaries. Explain or hide unsupported actions truthfully.
- Expose no handler for GitHub membership, label, phase, lane, lifecycle, or
  dependency mutations.

## Non-goals

- Fetch a missing issue/body on dialog open, parse workspace logs during
  render, own provider/activity caches, edit GitHub planning state, or replace
  the full interactive chat surface.
- Put issue bodies or action payloads into every card/worker/layout message.
- Optimistically claim an Aiur action succeeded before its authoritative owner
  confirms the result.

## Existing owner and reuse target

Extract reusable presentation/action seams alongside current Operator Control
Center detail/agent-log components. Reuse `Aiur.AgentLog`, `Aiur.AgentChat`,
Decision links, dashboard auth/writable checks, trusted GitHub URL policy, and
existing runtime-action confirmation semantics where available.

## Contract and invariants

- Context render accepts normalized cached data only and performs no network,
  filesystem, log, or process call.
- Cards remain body-free; selected context content is bounded and never enters
  BO-010's geometry worker.
- Relationship direction, edge state, and member readiness are separate named
  fields and use BO-007 truth unchanged.
- GitHub/planning behavior is read-only. Runtime action availability is checked
  again at invocation and remains capability/auth/writable/confirmation gated.
- Dialog labelling, focus trap, Escape/close, replacement navigation, and origin
  focus restoration are deterministic across LiveView patches.

## Refreshable implementation notes

- Refresh current dashboard detail/action components and the latest authenticated
  mutation safeguards on the configured integration branch before extracting.
- If selected bodies are not in the cached BO-003/007 snapshot contract,
  reconcile a bounded selected-context cache upstream rather than introducing a
  render-time fetch here.
- Keep each action adapter small and reuse existing authoritative control APIs;
  do not duplicate scheduler or agent-chat state.

## Acceptance and verification

### Agent gate

- Presenter/component tests cover every member lifecycle, invalid/external/
  missing endpoint, all five edge states, partial/stale providers, body-free
  cards, bounded selected content, safe/unsafe links, and action capability
  combinations.
- BO-008 browser tests cover mouse, Enter/Space, touch, focus trap, Escape,
  dependency replacement/back, LiveView patch, focus move/restore, and
  screen-reader relationship/status text.
- Action tests cover auth/writable/capability changes at invocation, confirmation,
  duplicate submit, pending, timeout, rejection, authoritative success, and no
  GitHub mutation handlers or render-time I/O.

### At-merge gate

- Shared component, existing detail/log/chat/action, auth/security,
  accessibility, compile/lint/spec, and full CI pass on the current configured
  integration branch.
- Any Units companion adopting context reuses this contract and serializes on
  shared components instead of forking it.

### Human/manual evidence

- Reviewer uses keyboard only to inspect a running, completed, invalid, and
  external ticket; follows both dependency directions; and exercises one
  supported runtime action through confirmation. BO-015 owns final proof.

## Failure, security, migration, and accessibility cases

- Validate safe GitHub links; sanitize descriptions; redact local paths,
  credentials, capability URLs, raw logs, provider errors, and account data.
- Preserve existing runtime action compatibility; no stored-data migration is
  introduced.
- Use semantic dialog/headings/lists/buttons, named pending/error states,
  minimum touch targets, non-color status, and deterministic focus restoration.

## Surfaces

- Reads: BO-007 selected cached context and adjacency; normalized runtime action
  capabilities; existing auth/writable state.
- Writes: reusable context presenter/components, navigation/focus state, thin
  authoritative runtime action adapters, and tests.
- Contracts: body-free card versus selected-context boundary; dependency
  navigation; gated runtime-action model.

## Sibling boundaries and open gates

BO-007 owns normalized truth and BO-012 wires card selection. A Units companion
may reuse this component but must serialize shared UI edits. Runtime actions are
not permission to expand Build Order into GitHub planning edits.
