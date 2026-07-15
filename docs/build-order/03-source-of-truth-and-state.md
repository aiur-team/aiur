# Build Order Source of Truth and State Model

## Decision

Build Order v1 is a read-only, same-repository projection composed from two
authorities:

- **GitHub** owns Build Order identity, membership, ticket content/metadata,
  lifecycle, and hard dependency relationships.
- **Aiur** owns current execution state, progress samples, active agent stage,
  alerts, and latest runtime evidence.

The presentation layer derives readiness, reverse edges, warnings, layout
groups, and summaries. It does not mutate GitHub planning data or parse
workspace logs. Shared ticket context may link to existing chat, Commands, and
control surfaces, but Build Order v1 exposes no mutating Aiur runtime handler;
those destination surfaces retain their independent contracts.

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
issues naturally support the dashboard selector. V1 defaults to a catalog of
at most 100 roots, with explicit page and provider-call ceilings. A catalog
that reaches the configured bound is probed for a bound-plus-one result and
reported as overflow rather than silently truncated.

A closed root with state reason `COMPLETED` means accepted. `NOT_PLANNED` means
cancelled. Child completion is shown separately and never closes/accepts the
root automatically.

## GitHub-owned member metadata

Use strict, single-valued labels:

- `complexity:1` through `complexity:5`;
- `phase:<positive integer>`;
- `build-lane:documentation|frontend|backend|infrastructure`.

Missing or duplicate complexity is unknown with a warning. Missing or duplicate
phase renders Unphased with a warning. Missing or duplicate lane renders
Unassigned. These member-local metadata failures remain renderable; they do not
invalidate an otherwise complete selected graph or hide other roots.
Icons are derived from lane/status with a generic fallback; no icon label is
needed in v1.

Every published planning issue carries one bounded hidden marker that binds its
logical identity to the immutable approved planning commit:

```html
<!-- aiur-planning-issue
{"schema":2,"logical_id":"BO-004","plan_version":1,"approved_planning_commit":"<40-char-sha>"}
-->
```

The approved planning pack retains planned/discovered provenance and
introduction version. The live marker deliberately does not duplicate labels,
membership, blockers, lifecycle, progress, runtime state or mutable
provenance. Validate marker schema, logical-ID uniqueness, commit resolution,
and the re-read issue-body hash during publication.

The root may carry the approved baseline pointer:

```html
<!-- aiur-planning-issue
{"schema":2,"logical_id":"its-everdred/aiur:build-order-dashboard","plan_version":1,"approved_planning_commit":"<40-char-sha>"}
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

## Five-valued edge and readiness policy

For each member:

- `ready`: dependency data is fresh and every blocker closed successfully;
- `blocking`: at least one known blocker is open;
- `terminal_unsatisfied`: a blocker closed without successful completion;
- `unknown`: membership, dependency, or blocker outcome is unavailable/stale;
- `cyclic`: the member participates in a strongly connected component or
  self-loop.

A blocker closed with `COMPLETED` clears its edge. A blocker closed with
`NOT_PLANNED` is terminal but unsatisfied until the relationship or successor
contract changes. Aiur progress—including `100%`—never clears an edge.

When multiple conditions apply, readiness uses the conservative precedence
`cyclic > unknown > terminal_unsatisfied > blocking > ready`. Edges carry the
parallel vocabulary `cleared | blocking | terminal_unsatisfied | unknown |
cyclic`; no unsatisfied terminal edge is styled as an actively running blocker.

Planned phase, dependency readiness, Aiur execution state, active CE stage, and
capacity/conflict eligibility are separate fields. Phase does not imply a
blocker. Detect cycles even if GitHub normally rejects cycle-creating writes.

## Dedicated GitHub graph projection

The landed ordinary issue path has no complete dependency-graph hydration. Do
not build this view on the in-flight PR #1012 per-issue `blocked_by` work
either. That proposed path is appropriate as a dispatch bridge but unsafe for a
100-node planning graph because it:

- performs N dependency requests and can exceed ordinary REST budgets;
- does not paginate beyond the dependency endpoint's default page;
- converts fetch failures to `[]`, making unknown appear unblocked;
- loses repository/node identity;
- has no atomic last-known-good generation or provider freshness.

Create an always-supervised `BuildOrderGitHubProjection` that owns all GitHub
I/O and caches by root node ID. It accepts only the configured repository and
rejects any other repository before provider I/O. Prefer bounded GraphQL reads
of root catalog, direct sub-issues, node/repository identity, labels/state, and
paginated `blockedBy` connections; use paginated REST only as a preserving
fallback. Enforce configurable maximum roots, pages and provider calls for the
catalog plus GitHub's 100-member selected-root limit, and prove the overflow
case. Inspect query cost/rate limits and reject partial results unless failures
are explicitly modeled.

Root-catalog and selected-root refreshes have independent health. One malformed
root becomes a catalog diagnostic and cannot erase other selectable roots.
Each selected-root refresh builds a complete candidate generation, validates
structure/counts/endpoints/cycles, records member-local metadata warnings, and
atomically replaces the snapshot only on success. A structurally invalid
selected root is distinct from provider failure. On auth, rate-limit, timeout,
partial response, pagination mismatch, or malformed structural data:

- preserve the last-known-good graph;
- mark it stale with last success/attempt, failure class, and retry time;
- never publish a partially cleared edge set;
- show unavailable/unknown if no prior generation exists.

Cache and coalesce per daemon, publish generation changes over PubSub, and keep
GitHub polling out of LiveView. The configurable defaults are a 60-second root
catalog interval and a 15-second selected-root interval. Selecting a root or
reconnecting a browser demands a coalesced refresh when that snapshot is older
than 5 seconds, then renders the current snapshot while the refresh proceeds.
Deterministic projection/LiveView tests prove healthy pushed updates arrive
within the configured bound and failed refreshes retain visibly stale LKG
state. Webhooks for `issue_dependencies` and `sub_issues` may invalidate the
cache later, but periodic reconciliation remains authoritative and webhook
support is not a v1 prerequisite.

## Shared Aiur activity projection

Progress, active CE phase, and latest event currently live inside the interactive
AgentList process and are pruned with its visible roster. Headless runs and the
dashboard cannot safely depend on that UI-owned state.

First add a typed tracker identity to normalized issues. For GitHub it retains
the configured owner/repository and provider node ID already present on
ordinary issue responses; the display number remains a locator and the legacy
dispatch key remains unchanged. Propagate that identity through orchestrator
StatusReport, which already owns execution lifecycle, waiting reason,
backend/model, and latest-worker facts. A missing legacy node ID is unjoinable,
not permission to fall back to the current directory or a bare number.

Next extend the ticket-scoped event envelope so the same identity is present or
resolved from a frozen tracked-issue snapshot at trusted ingestion. Never infer
it from a bare event topic or display name. Extract only the event-derived
AgentList fold into an always-supervised `TicketActivityProjection` consumed by
AgentList and dashboard. Key it by that typed identity. Per ticket retain:

- latest safe cross-ticket event/evidence and observed time;
- progress value, source, observed time, and staleness;
- active agent stage (`brainstorm`, `plan`, `work`, `review`), explicitly not
  the planned rollout phase; and
- projection health/availability.

Do not copy execution, queue/retry/paused state, waiting reason, backend/model,
or latest worker status into this projection. Those remain StatusReport facts.
The standalone DASH-002 catalog owns full-current-run membership and terminal
retention; a bounded event projection is not a run ledger.

In-memory v1 state is acceptable if restart behavior is honest: after restart,
active progress is unknown until replay or a new event. A GitHub issue closed
successfully may show outcome completion, but open tickets with absent/stale
Aiur samples show unknown, not `0%`. LiveView never parses workspace logs.

## Bounded ticket detail, history, and context

Ticket cards carry bounded summaries only. Selecting a typed ticket demands a
root-independent configured-repository detail snapshot that may include the
current GitHub description and safe tracker URL. The provider is cached,
coalesced, independently healthy, and rejects another repository before I/O;
it is not coupled to Build Order membership or graph refresh.

A separate daemon-owned recent-history provider projects a bounded, sanitized
timeline from supported Aiur event and issue-log seams using the same typed
identity. It excludes prompts, transcripts, credentials, environment values,
local paths and unbounded raw output. Browser render never scans workspace log
files, and a missing history source is an explicit unavailable/partial state.

An accessible base context composes detail, current progress/latest evidence,
and bounded recent history into Description, Progress, and Logs sections plus
truthful destination capabilities. The Build Order adapter adds only selected
graph relationships and diagnostics. “Read chat,” “View command,” and “Open
GitHub” are shown only when their separately owned destination can resolve the
exact ticket; navigation is not evidence that an action succeeded. Units may
reuse the base context without importing Build Order relationships.

## Normalized snapshots

The GitHub snapshot contains root identity/acceptance, node IDs and mutable
locators, member metadata/state, dependency edges/external refs, cycle/data
quality, generation, and provider health.

The Aiur side contains two immutable inputs keyed by the same typed tracker
identity: an orchestrator StatusReport snapshot for execution/waiting/provider
facts and a TicketActivity snapshot for progress/stage/cross-ticket evidence.
Each retains its own observation time and health.

Selection adds independently cached configured-repository TicketDetail and
bounded TicketHistory inputs. They remain outside graph-card generations so a
slow body/history source cannot make membership or blockers disappear.

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
BuildOrderPresenter <---------- StatusReport <---------------- Orchestrator
        ^
        +---------------------- TicketActivityProjection <---- Aiur events
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
- pricing/spend estimation inside the bounded Build Order feature (the
  standalone companion program owns it);
- treating planning conflict edges as GitHub dependency edges unless they are a
  true semantic serialization prerequisite.

These boundaries keep GitHub authoritative, make multiple Build Orders
selectable without mixed tickets, and avoid introducing a second planning
database inside Aiur.
