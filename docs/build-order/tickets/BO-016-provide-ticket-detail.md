# BO-016 — Provide configured-repository ticket detail

**Kind:** executable

**Provenance:** planned in plan v1

**Complexity:** 4 — Configured-repository GitHub provider and supervised bounded sanitized LKG cache

**Risk:** high

**Phase hint:** 4

**Depends on:** BO-004

**Serializes with:** BO-003, BO-005, BO-019, DASH-002, DASH-009, DASH-012, DASH-018, DASH-019, DASH-024, DASH-025, DASH-026 — application supervision tree

**Requirements:** BOREQ-011

**Decisions:** DEC-001, DEC-005

**Design evidence:** DESIGN-001

**Researched at:** 9849f32963c2a65367bce565b3f5ede3777c218f

**Suggested labels:** `complexity:4`, `model:codex-gpt-5.6-sol`, `phase:4`, `build-lane:plan-graph`; never `agent:todo`

## Outcome

A trusted issue in the configured GitHub repository can be loaded on demand
into one bounded, sanitized, health-aware detail cache; a request for any other
repository is rejected before provider I/O.

## Context and evidence

Graph cards must stay body-free at the 100-member bound, while a selected
ticket needs a richer description. Fetching in LiveView or once per card would
scale with browser/member count and could leak bodies into layout payloads.
BO-004 provides one configured-repository identity; this ticket owns only
provider/cache behavior. BO-018 later renders it.

## Scope

- Define an on-demand detail request/snapshot keyed by BO-004 tracker kind,
  exact configured repository, and canonical provider issue identity. Number is
  a validated locator/display value, never the join key.
- Reject mismatched/other-repository identities before constructing a provider
  request, consuming rate limit, or touching the cache. Return a typed
  nonfetchable-repository result suitable for BO-007/011 diagnostics.
- Add a bounded GitHub read through existing authenticated transport for
  normalized title, bounded sanitized description, lifecycle outcome, safe
  canonical URL, timestamps, and explicitly approved detail facts.
- Preserve structured auth, permission, rate-limit, timeout, schema, not-found,
  validation, and repository-mismatch failures without raw responses/secrets.
- Add one supervised on-demand cache with concurrent-demand coalescing, bounded
  retention/eviction, monotonic generations, configurable freshness,
  last-known-good preservation, no-LKG unavailable state, and explicit
  in-memory restart behavior.
- Prevent delayed/failed requests from overwriting newer generations or leaking
  data across identities. Never hydrate all graph members.

## Non-goals

- Render a context component, activity/progress/latest/log history,
  relationship groups, destination CTAs, or root-selection focus.
- Support arbitrary/cross-repository reads, Linear, graph/catalog hydration, or
  per-browser polling.
- Mutate GitHub or invoke any Aiur runtime action.

## Existing owner and reuse target

Extend current GitHub transport/auth/normalization and OTP provider/cache
patterns. Consume BO-004 identity exactly; do not introduce a second identity
or Build Order root/member field.

## Contract and invariants

- Cache/provider identity always equals BO-004's configured repository plus
  provider node identity. Mismatch rejects before I/O and cache lookup/write.
- Successful snapshots are complete, bounded, sanitized, immutable, and tied
  to generation/observation time. Partial data is preserving failure.
- Failed refresh changes health, not LKG content. Cold/restart without LKG is
  unavailable, never empty/fabricated detail.
- Demand/retention are bounded independently of browsers. Identical concurrent
  demand coalesces; distinct identities never share results.
- No root, membership, adjacency, edge/readiness, activity, or CTA field enters
  this contract.

## Refreshable implementation notes

- Reinspect current GitHub transport, BO-004 identity, supervision/cache,
  configuration, safe-URL policy, and test factories at pickup.
- Reconcile application supervision edits with BO-003, BO-005, and BO-019
  before overlapping branches merge.
- Use injected clock/tasks and deterministic barriers rather than sleeps.
- Publish a narrow snapshot/query/subscription seam for BO-018.

## Acceptance and verification

### Agent gate

- Tests cover configured identity, same-number collision, mismatch rejection
  before mocked transport invocation, cold start, coalescing, eviction, stale
  LKG, no-LKG failure, recovery, timeout, delayed completion, restart,
  not-found, and every structured failure.
- Bounds/redaction tests cover malformed/oversized title/body/URL/error values
  and prove credentials, raw responses, private headers, local paths, and
  unapproved content never enter snapshots/evidence.
- Negative tests prove no graph-wide hydration, per-browser polling, other-repo
  I/O, relationship state, UI, or mutation handler.

### At-merge gate

- GitHub transport, provider/cache, supervision, auth/security,
  compile/lint/spec, and full repository CI pass on the configured integration
  branch.
- BO-018 consumes the published snapshot without provider access.

### Human/manual evidence

- None separately; BO-015 proves detail and other-repository diagnostics.

## Failure, security, migration, and accessibility cases

- Use configured GitHub auth/host policy; never cache/log credentials, raw
  authorization, private responses, local paths, or unbounded content.
- No durable migration; document in-memory loss and recovery after restart.
- Typed health/errors support concise accessible rendering by BO-018.

## Surfaces

- Reads: BO-004 configured-repository identity; GitHub detail transport/auth;
  provider/cache configuration.
- Writes: configured-repository detail adapter/cache; health/freshness,
  redaction, supervision, and provider tests.
- Safety: ticket-detail privacy/no-mutation boundary and application
  supervision tree.
- Contracts: on-demand detail snapshot/health; reject-before-I/O repository
  boundary; complete/LKG/unavailable semantics.

## Sibling boundaries and open gates

BO-018 owns accessible base context, BO-019 owns recent history, BO-011 owns
Build Order relationships/destinations, and BO-002/003 remain body-free graph
providers. BO-003, BO-005, and BO-019 share only the application supervision
tree with this ticket and serialize on that seam. Other-repository endpoints
are diagnostics/validated outbound links, never detail requests.

## Plan context

Where this ticket fits in the wider Build Order (all paths pinned to the
approved planning commit linked in this issue's preamble):

- [Pack index and read-first order](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/README.md)
- [Your implementation pointers](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/08-implementation-pointers.md) — section `BO-016`
- [Graph waves, critical path, and parallelism](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/07-graph-parallelism-review.md)
- [Technical decisions (DEC-*)](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/build-order/05-technical-decisions.md)
- [Requirements](https://github.com/its-everdred/aiur/blob/<APPROVED_SHA>/docs/brainstorms/2026-07-12-build-order-requirements.md)
- Your issue's native parent is the Build Order root; native `blockedBy`
  edges are the dependency graph — the root issue renders the full picture.
