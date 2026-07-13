# BO-016 — Build repository-qualified ticket context

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Repository-qualified provider, supervised cache, and reusable accessible context boundary

**Risk:** high

**Phase hint:** 4

**Depends on:** BO-004, BO-008

**Serializes with:** none

**Requirements:** BOREQ-011

**Decisions:** DEC-001, DEC-005, DEC-008, DEC-009

**Design evidence:** DESIGN-001

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:4`, `model:codex`, `phase:4`, `build-lane:frontend`; never `agent:todo`

## Outcome

Any trusted repository-qualified GitHub issue can be loaded on demand into one
bounded, health-aware cache and rendered through an accessible read-only base
ticket context, independent of Build Order roots, membership, or relationships.

## Context and evidence

The dashboard needs richer selected-ticket information in more than one place,
but graph-wide GitHub hydration would multiply provider cost and expose issue
bodies in every card/layout payload. The current agent-log detail surface is
optimized for active agents and may perform runtime lookups, while a completed,
queued, invalid, external, or provider-unavailable ticket still needs truthful
context. A reusable owner therefore needs repository-qualified identity,
on-demand I/O, cache health, bounded content, and accessible presentation before
Build Order-specific relationships are added.

This ticket deliberately has no Build Order root dependency. BO-004 supplies
the trusted tracker identity and identity-bearing status seam; BO-008 supplies
the real-browser accessibility harness. BO-011 later adapts the resulting base
context to Build Order adjacency and root-scoped focus without contaminating
this reusable contract.

## Scope

- Define a root-independent ticket-detail request and snapshot keyed by
  BO-004's tracker kind, repository identity, and canonical provider issue
  identity. Issue number is a validated locator/display value, never the join
  key by itself.
- Add a bounded GitHub read operation through the existing authenticated
  transport for the selected issue's normalized title, bounded sanitized
  description, lifecycle outcome, safe canonical URL, timestamps, and other
  explicitly approved detail facts. Preserve structured auth, permission,
  rate-limit, timeout, schema, not-found, and validation failures.
- Add one supervised on-demand cache/projection with concurrent-demand
  coalescing, bounded retention/eviction, monotonic generations, configurable
  freshness, last-known-good preservation, explicit no-LKG unavailable state,
  and documented in-memory restart behavior.
- Keep detail health independent per repository-qualified ticket. A failed or
  delayed request cannot overwrite a newer generation or leak data across two
  repositories that share an issue number.
- Define a pure presenter and accessible base context component for loading,
  available, stale, unavailable, not-found, invalid, open, terminal, and
  optional identity-bearing execution/status inputs. Rendering performs no
  provider, filesystem, log, clock, or process lookup.
- Render bounded title/description, canonical tracker identity, lifecycle,
  provider health/freshness, optional normalized execution provenance, and
  validated safe GitHub or existing destination links. A link is navigation,
  not evidence that an action succeeded.
- Own generic component labelling, heading focus entry, focus trap, Escape and
  close callback, responsive reflow, non-color states, and loading/error text.
  Callers own the origin to which focus returns and any domain-specific
  replacement-navigation policy.
- Expose no handler for GitHub issue, label, state, membership, or dependency
  mutation and no handler for chat, Decisions, pause/resume, capacity, retry,
  or any other Aiur runtime mutation.

## Non-goals

- Know or infer a Build Order root, membership, parent, adjacency, blocker
  direction, edge/readiness state, phase, lane, dependency diagnostic, or root
  selection lifecycle.
- Hydrate every issue in a graph/catalog, poll once per connected browser, or
  put issue descriptions into card, SVG, or worker payloads.
- Join GitHub planning data to Aiur activity, parse logs, replace AgentList,
  implement Linear parity, or own a Units-only action/control protocol.
- Add any mutation handler merely because a destination surface already has
  one.

## Existing owner and reuse target

Extend the current GitHub transport/auth/normalization and OTP provider/cache
patterns, BO-004's repository-qualified tracker identity, current dashboard
authentication/safe-route policy, and existing accessible dialog/component
conventions. Extract only reusable read-only presentation from current detail
or agent-log surfaces; do not copy their live process lookups or action
handlers.

## Contract and invariants

- The cache key always includes tracker kind, repository, and canonical opaque
  provider identity. Bare issue number, title, event topic, active workflow, and
  workspace path are never sufficient.
- A successful snapshot is complete, bounded, sanitized, immutable, and tied
  to its observation/generation. Partial provider data is a preserving failure,
  never a smaller successful detail record.
- Failed refresh changes health metadata but not last-known-good content. Cold
  start/restart without an LKG is unavailable, never an empty description or
  fabricated current snapshot.
- Provider demand and retained entries are bounded independently of connected
  browsers. Concurrent identical demand coalesces; different repository
  identities cannot share results.
- The presenter/component consumes normalized cached values only. Optional
  execution/status facts retain their source and observation time and never
  overwrite GitHub lifecycle truth.
- The base context has no root, member, adjacency, edge, readiness, or
  relationship-group field. Domain adapters may compose around it without
  modifying this contract.
- Safe destination availability is normalized and checked again by the
  destination. The base component has no mutation event handler.

## Refreshable implementation notes

- Reinspect the current GitHub transport, issue normalizer, StatusReport shape,
  application supervision/cache conventions, dashboard detail components,
  auth policy, and route-link helpers on the configured integration branch.
- Prefer a small provider boundary, deterministic injected clock/tasks, and an
  independently testable pure presenter/component. Avoid render-time calls and
  sleep-based cache tests.
- Keep the component extension seam typed and narrow so BO-011 can add
  relationship sections and root-scoped focus without forking the base markup
  or cache.

## Acceptance and verification

### Agent gate

- Provider/cache tests cover two repositories with the same issue number,
  canonical identity mismatch, cold start, success, concurrent coalescing,
  bounded eviction, stale LKG, no-LKG failure, recovery, timeout, out-of-order
  completion, restart, not-found, and every structured failure without sleeps.
- Bounds/redaction tests cover oversized or malformed title/body/URL/provider
  values and prove credentials, raw responses, local paths, private headers,
  and unapproved runtime content never enter snapshots or evidence.
- Presenter/component tests cover every lifecycle/provider state, optional
  execution facts, safe/unsafe links, semantic headings/status, focus entry/
  trap/Escape/close, responsive reflow, forced colors, reduced motion, and 200%
  text zoom through BO-008's harness.
- Negative tests prove no root/member/adjacency/edge/readiness fields, no
  graph-wide hydration, no per-browser polling, and no GitHub or Aiur mutation
  handler exist.

### At-merge gate

- GitHub transport, provider/cache, supervision, component, auth/security,
  accessibility, real-browser, compile/lint/spec, and full repository CI pass
  on the current configured integration branch.
- BO-011's published adapter input composes this contract without requiring a
  Build Order field or changing the base provider/cache/component.

### Human/manual evidence

- Reviewer uses keyboard only to open repository-qualified running, completed,
  unavailable, stale, and invalid tickets; checks focus and safe navigation;
  and confirms the base context contains neither relationship UI nor mutation
  controls. BO-015 owns final integrated proof.

## Failure, security, migration, and accessibility cases

- Use configured GitHub auth and trusted repository/host policy; never cache or
  render credentials, raw authorization headers, private provider responses,
  local paths, capability URLs, or unbounded issue content.
- No durable-state migration is introduced. Document in-memory cache loss and
  provider recovery after restart explicitly.
- Use semantic dialog/region, headings, status text, native links/buttons,
  visible focus, minimum touch targets, non-color state, forced-color support,
  reduced motion, and deterministic close behavior.

## Surfaces

- Reads: BO-004 repository-qualified tracker identity and identity-bearing
  status seam; GitHub issue-detail transport/auth conventions; BO-008 browser/
  accessibility harness; safe dashboard route capabilities.
- Writes: repository-qualified ticket-detail adapter/cache; health/freshness
  snapshots; accessible base `TicketContext` presenter/component and tests.
- Contracts: on-demand ticket-detail snapshot and health; root-independent
  accessible base ticket context; no-mutation ticket-context boundary.

## Sibling boundaries and open gates

BO-004 owns canonical tracker identity, BO-008 owns browser infrastructure,
BO-011 alone owns Build Order relationship/edge/root-selection adaptation, and
BO-007 owns graph/activity truth. BO-002/003 remain limited to body-free Build
Order graph transport and projection. Dashboard companions may reuse this base
context but must define any action protocol elsewhere and serialize shared
component edits rather than widening this ticket.
