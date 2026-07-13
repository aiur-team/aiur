# BO-018 — Build accessible base ticket context

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 3 — Accessible reusable context composition over established detail, history, and browser contracts

**Risk:** high

**Phase hint:** 4

**Depends on:** BO-008, BO-016, BO-019

**Serializes with:** none

**Requirements:** BOREQ-011

**Decisions:** DEC-001, DEC-008, DEC-009

**Design evidence:** DESIGN-001

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:3`, `model:codex`, `phase:4`, `build-lane:frontend`; never `agent:todo`

## Outcome

An accessible, root-independent base context renders configured-repository
description, progress/latest evidence, a bounded Logs timeline, and normalized
read-only GitHub/Chat/Commands destination CTAs without Build Order
relationships or mutation handlers.

## Context and evidence

Selected context is useful outside a Build Order graph, but current agent-log
UI is optimized for running entries and can perform runtime lookups. BO-016 and
BO-019 establish bounded daemon/provider snapshots. This ticket owns their pure
accessible presentation and a generic destination-capability model. BO-011
later decides which concrete Build Order destinations/relationships apply.

## Scope

- Define a pure all-state presenter over BO-016 detail plus BO-019 progress,
  latest evidence, bounded history, freshness, missing, stale, unavailable, and
  restart states. Rendering performs no provider/log/process/filesystem lookup.
- Render bounded title/description, canonical configured-repository identity,
  GitHub lifecycle, detail/history health/freshness, progress with provenance,
  latest safe evidence, and a semantic `Logs` timeline with truncation/state.
- Define a normalized navigation-only CTA model for `GitHub`, `Chat`, and
  `Commands`: label, safe href/route, availability, disabled/unavailable reason,
  and destination kind. This component renders supplied capabilities but never
  determines Build Order eligibility or claims an action succeeded.
- Own generic semantic dialog/region labelling, heading focus entry, focus trap,
  Escape/close callback, responsive reflow, loading/error/status text, forced
  colors, reduced motion, and 200% text zoom through BO-008.
- Bound visible text/timeline content and preserve provider/activity source and
  observation times. Callers own origin focus restoration and domain-specific
  replacement navigation.
- Expose navigation only. No GitHub planning mutation or chat/Decision/control/
  pause/resume/capacity/retry action handler exists in the component.

## Non-goals

- Know Build Order root/membership, adjacency, blocker direction, edge/readiness
  diagnostics, root selection, or concrete destination eligibility.
- Fetch GitHub, query/parse logs, subscribe directly to raw events, own caches,
  or infer missing data.
- Add mutation controls or duplicate Units/Commands/chat action protocols.

## Existing owner and reuse target

Compose BO-016/019 public snapshots with current dashboard auth, safe route-link
policy, and accessible dialog/component conventions. Keep a typed extension seam
for BO-011 rather than forking provider or markup ownership.

## Contract and invariants

- Presenter/component inputs are normalized cached snapshots only. Missing,
  stale, unavailable, known-empty, and restart states stay distinct.
- Description and Logs remain bounded/sanitized; raw provider/log/model content
  is never accepted.
- CTA rendering is truth-preserving: unavailable capability has a reason and no
  actionable link; available capability is navigation to a separately
  authorized destination, not an action result.
- Base context has no root/member/adjacency/edge/readiness field and cannot
  fetch other-repository detail.
- Focus entry/trap/Escape/close is deterministic; callers supply origin focus
  and domain replacement policy.
- No mutation handler exists.

## Refreshable implementation notes

- Refresh BO-016/019 shapes, current dialog/focus helpers, safe route
  components, auth state, and BO-008 helpers on the configured branch.
- Prefer a pure presenter plus small component; do not store provider/cache
  state in LiveView.
- Keep CTA model route-agnostic enough for reuse but restrict it to the three
  accepted read-only destination kinds.

## Acceptance and verification

### Agent gate

- Presenter/component tests cover every detail/history/lifecycle state, bounded
  description, progress provenance, latest evidence, 0/1/50/100 Logs entries,
  truncation, stale/missing/restart, and configured-repository identity.
- CTA tests cover available/unavailable GitHub/Chat/Commands, explicit reasons,
  safe/unsafe links, unknown kinds, and proof navigation never invokes an action.
- BO-008 browser tests cover keyboard/touch, focus entry/trap/Escape/close,
  semantic headings/status/list, responsive reflow, forced colors, reduced
  motion, theme, and 200% zoom.
- Security tests prove no raw logs/provider errors, other-repository fetch,
  relationship field, or mutation handler.

### At-merge gate

- Detail/history/component/route-link/auth/security/accessibility/browser,
  compile/lint/spec, and repository CI pass on the configured branch.
- BO-011 composes the published extension/CTA seam without changing base
  provider, focus, or markup contracts.

### Human/manual evidence

- Reviewer opens running, completed, stale, unavailable, missing-history, and
  restart contexts by keyboard; checks bounded Logs/focus; and verifies truthful
  CTA availability with no relationship or mutation controls.

## Failure, security, migration, and accessibility cases

- Redact/bound content before presentation; never expose credentials, raw
  responses/logs/prompts/output, capability URLs, account data, or local paths.
- No stored migration; component state is disposable.
- Semantic native controls, status/list structure, visible focus, touch targets,
  non-color states, forced colors, reduced motion, and zoom are required.

## Surfaces

- Reads: BO-008 browser/a11y harness; BO-016 detail snapshots; BO-019 history
  snapshots; normalized navigation-only destination capabilities.
- Writes: accessible base TicketContext presenter/component; description,
  progress/latest, Logs, CTA, focus, security, and browser tests.
- Contracts: root-independent base context; normalized GitHub/Chat/Commands CTA
  model; generic focus lifecycle; no-mutation boundary.

## Sibling boundaries and open gates

BO-016 owns detail, BO-019 owns history, and BO-011 alone owns Build Order
relationships, root focus/restoration, and concrete destination binding. Other
dashboard surfaces may reuse this component but define actions elsewhere.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `BO-018`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
