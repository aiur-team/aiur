# Build Order Source of Truth and State Model

## Decision

Build Order v1 is a read-only, same-repository projection composed from two
authorities:

- **GitHub** owns Build Order identity, membership, ticket content/metadata,
  lifecycle, and hard dependency relationships.
- **Aiur** owns current execution state, progress samples, active agent stage,
  alerts, and latest runtime evidence.

The presentation layer derives readiness, reverse edges, warnings, layout
groups, and summaries. It does not mutate GitHub or parse workspace logs.

## GitHub identity and membership

Each Build Order is a normal root GitHub issue in the configured tracker
repository with one constant `build-order` label. The root's canonical key is
its GitHub global issue node ID; `{owner, repo, number, url}` is a mutable human
locator, and the REST numeric database ID is retained for relationship writes.

Members are the root's direct native sub-issues:

- same configured repository as the root;
- direct children only;
- no nested member sub-issues in v1;
- one parent, so one Build Order membership per ticket;
- at most 100 members, matching GitHub's direct-child limit.

The constant label discovers roots; it is not copied onto members. Do not add a
`build-order:<slug>` label that duplicates native parenthood. Multiple root
issues naturally support the dashboard selector.

A closed root with state reason `COMPLETED` means accepted. `NOT_PLANNED` means
cancelled. Child completion is shown separately and never closes/accepts the
root automatically.

## GitHub-owned member metadata

Use strict, single-valued labels:

- `complexity:1` through `complexity:5`;
- `phase:<positive integer>`;
- `build-lane:documentation|frontend|backend|infrastructure`.

Missing or duplicate complexity is unknown/invalid. Missing or duplicate phase
renders Unphased with a warning. Missing or duplicate lane renders Unassigned.
Icons are derived from lane/status with a generic fallback; no icon label is
needed in v1.

Store only stable planning identity/provenance in a hidden JSON issue-body
marker:

```html
<!-- aiur-build-order-ticket
{"schema":1,"logical_id":"BO-004","provenance":"planned","introduced_in_plan_version":1}
-->
```

For discovered work, use `"provenance":"discovered"` and add
`"discovered_from":"BO-002"` when applicable. Validate logical-ID uniqueness
within the root. Do not duplicate labels, membership, blockers, live state, or
progress in this block.

The root may carry the approved baseline pointer:

```html
<!-- aiur-build-order-root
{"schema":1,"plan_version":1,"approved_planning_commit":"<40-char-sha>"}
-->
```

## Blocker syntax

The blocker source is GitHub's native issue-dependency relationship, not body
prose. The authoritative operation is equivalent to “blocked issue is blocked
by blocking issue,” already exposed to agents through `aiur_declare_blocker`
and `aiur_unblock`.

Direction in the graph is:

```text
blocking issue -> blocked issue
```

`Depends on`, `Blocks`, Mermaid arrows, checklists, and ticket-body summaries
are generated human views. `/aiur-build` must publish native relationships and
requery them; it must fail validation when generated prose disagrees. This
avoids the existing OCC drift where issue bodies declare dependencies but the
native graph omits them.

External blockers are retained as references and affect readiness even when
their full cards are not rendered. A missing/out-of-order endpoint must never
disappear as if no blocker existed.

## Four-valued readiness

For each member:

- `ready`: dependency data is fresh and every blocker closed successfully;
- `blocked`: at least one known blocker is open;
- `unknown`: membership, dependency, or blocker outcome is unavailable/stale;
- `cyclic`: the member participates in a strongly connected component or
  self-loop.

A blocker closed with `COMPLETED` clears its edge. A blocker closed with
`NOT_PLANNED` is terminal but unsatisfied until the relationship or successor
contract changes. Aiur progress—including `100%`—never clears an edge.

Planned phase, dependency readiness, Aiur execution state, active CE stage, and
capacity/conflict eligibility are separate fields. Phase does not imply a
blocker. Detect cycles even if GitHub normally rejects cycle-creating writes.

## Dedicated GitHub graph projection

Do not build this view on PR #1012's per-issue `blocked_by` hydration. That path
is appropriate as a dispatch bridge but unsafe for a 100-node graph because it:

- performs N dependency requests and can exceed ordinary REST budgets;
- does not paginate beyond the dependency endpoint's default page;
- converts fetch failures to `[]`, making unknown appear unblocked;
- loses repository/node identity;
- has no atomic last-known-good generation or provider freshness.

Create an always-supervised `BuildOrderGitHubProjection` that owns all GitHub
I/O and caches by root node ID. Prefer bounded GraphQL reads of root catalog,
direct sub-issues, node/repository identity, labels/state, and paginated
`blockedBy` connections; use paginated REST only as a preserving fallback.
Inspect query cost/rate limits and reject partial results unless failures are
explicitly modeled.

Each selected-root refresh builds a complete candidate generation, validates
counts/endpoints/cycles/metadata, and atomically replaces the snapshot only on
success. On auth, rate-limit, timeout, partial response, pagination mismatch,
or malformed data:

- preserve the last-known-good graph;
- mark it stale with last success/attempt, failure class, and retry time;
- never publish a partially cleared edge set;
- show unavailable/unknown if no prior generation exists.

Cache and coalesce per daemon, publish generation changes over PubSub, and keep
GitHub polling out of LiveView. Webhooks for `issue_dependencies` and
`sub_issues` may invalidate the cache later, but periodic reconciliation remains
authoritative and webhook support is not a v1 prerequisite.

## Shared Aiur activity projection

Progress, active CE phase, and latest event currently live inside the interactive
AgentList process and are pruned with its visible roster. Headless runs and the
dashboard cannot safely depend on that UI-owned state.

Extract the fold into an always-supervised `TicketActivityProjection` consumed
by AgentList and dashboard. Key it by a typed tracker identity containing
provider/repository identity, never a bare issue number. Per ticket retain:

- execution state and explicit waiting reason;
- latest event/evidence and observed time;
- progress value, source, observed time, and staleness;
- active agent stage (`brainstorm`, `plan`, `work`, `review`), explicitly not
  the planned rollout phase;
- provider health/availability.

In-memory v1 state is acceptable if restart behavior is honest: after restart,
active progress is unknown until replay or a new event. A GitHub issue closed
successfully may show outcome completion, but open tickets with absent/stale
Aiur samples show unknown, not `0%`. LiveView never parses workspace logs.

## Normalized snapshots

The GitHub snapshot contains root identity/acceptance, node IDs and mutable
locators, member metadata/state, dependency edges/external refs, cycle/data
quality, generation, and provider health.

The Aiur snapshot contains activity keyed by typed tracker identity plus its own
observed time/health.

A pure presenter joins them into cards and edges with:

- separate plan and activity subrecords;
- readiness and satisfaction classification;
- phase/lane groups and deterministic icons;
- upstream/downstream adjacency for highlighting;
- counts, warnings, and provider freshness.

The presenter performs no fetch, mutation, log parsing, or missing-data default.

```text
GitHub GraphQL / paginated REST
        |
        v
BuildOrderGitHubProjection ---- complete generation + last-known-good cache
        | PubSub
        v
BuildOrderPresenter <---------- TicketActivityProjection <----- Aiur events
        |
        v
Dashboard LiveView ------------ selected root + canvas interaction state
```

## V1 non-goals

- editing membership, labels, phase/lane, or dependencies in the dashboard;
- cross-repository or Linear-backed Build Orders;
- one ticket in multiple Build Orders;
- more than 100 direct members or nested workstream visualization;
- webhook-only consistency;
- pricing/spend estimation;
- treating planning conflict edges as GitHub dependency edges unless they are a
  true semantic serialization prerequisite.

These boundaries keep GitHub authoritative, make multiple Build Orders
selectable without mixed tickets, and avoid introducing a second planning
database inside Aiur.
