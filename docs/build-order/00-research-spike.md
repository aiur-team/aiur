# Build Order Research Spike

**Status:** In progress  
**Scope:** Feature decomposition and reusable planning workflow only. This spike
does not implement Build Order or run Aiur.

## Working Outcome

Build Order should be a GitHub-owned planning graph with an Aiur-owned runtime
overlay. GitHub remains authoritative for which tickets belong to an order,
their metadata, and their dependency edges. Aiur contributes live execution
state, progress estimates, workflow phase, recent activity, and event evidence
without copying those facts back into a second planning database.

The initial implementation size hypothesis is ten Build Order tickets. Separate
dashboard companion work currently comprises Units, Commands, and three
usage/accounting tickets. Those tickets do not belong to the Build Order root
or its completion math. Final counts follow independently reviewable dependency
boundaries, not a quota.

## Current Dashboard Baseline

As of `origin/main` at `e5f07d02`, the Operator Control Center from PR #1037 is
already merged. `src/lib/aiur_web/router.ex` exposes Fleet at `/`, the Decision
inbox at `/decisions`, stable decision detail routes, and the separate offline
analytics page at `/analytics`.

`src/lib/aiur_web/live/dashboard_live.ex` is the LiveView shell.
`src/lib/aiur_web/control_center_presenter.ex` composes independently-degrading
fleet, decision, history, outcome, and analytics providers. The UI is split
under `src/lib/aiur_web/components/operator_control_center/`; the fleet table
currently shows ticket, state, explicit waiting reason, latest activity,
elapsed time, decision count, and tracker/log actions.

There is no Build Order or Commands route on `origin/main`. The completed delta
is recorded in `02-dashboard-design-delta.md`.

## What PR #971 Demonstrates

PR #971 began as a planning-only Operator Control Center branch with this
artifact hierarchy:

1. A PRD as the product source of truth.
2. A brainstorm/decomposition document with ticket, dependency, and
   parallelism tables.
3. A design prompt for an external visual artifact.
4. Issue-ready ticket documents and exported GitHub issues.
5. An Executor handoff updated as the fleet ran.

The decomposition started at OCC-0 through OCC-9, then added OCC-10 as an
integration capstone after parallel UI/backend work exposed a missing
end-to-end ownership boundary. That capstone is evidence that every parallel
wave needs an explicit integration/proof owner when independently-built slices
can each be locally correct without composing into a working user flow.

PR #971 is not itself a reliable current-state source. Its branch now conflicts
with `main`, contains unrelated implementation ancestry, and its Executor
handoff is a time-stamped operational snapshot. The durable product and ticket
artifacts remain useful; current state must come from GitHub issues/PRs and the
current repository.

## Existing Decomposition Patterns

The OCC and large-refactor precedents consistently use:

- a requirements or PRD document that owns product behavior;
- a small index/handoff document that says what to read first;
- one issue-ready document per ticket;
- `complexity:1` through `complexity:5` labels;
- `phase:N` or priority labels for rollout order;
- explicit `Depends on` and `Parallel with` fields;
- a critical path plus Mermaid dependency graph;
- file-overlap analysis so nominally parallel tickets do not serialize on the
  same modules;
- a research/audit ticket before irreversible architectural choices;
- an integration capstone and end-to-end proof ticket;
- an Executor handoff that records live state, decisions, blockers, and next
  actions rather than restating the PRD.

The most useful constraint from `docs/refactor/phasing-and-parallelization.md`
is stronger than ordinary dependency planning: tickets scheduled concurrently
must be both dependency-independent and file-disjoint.

## The Current Source-of-Truth Gap

Aiur already has GitHub-native dependency support:

- `src/lib/aiur/github/dependencies_api.ex` reads and mutates `blocked_by` and
  `blocking` edges using GitHub API version `2026-03-10`.
- `src/lib/aiur/github/issue_dependencies.ex` adds idempotency and bounded
  cycle detection.
- `aiur_declare_blocker` and `aiur_unblock` expose the same graph to agents.
- `Aiur.Issue.blocked_by` is the tracker-neutral normalized field used by
  dispatch policy and dependency events.

However, `src/lib/aiur/github/issues.ex` on `origin/main` does not hydrate those
edges into ordinary issue polls. PR #1012 is adding hydration. Its current
failure behavior converts a failed dependency request to `blocked_by: []`,
which is unsafe for Build Order: an unavailable graph would render as a graph
with no blockers. Build Order needs last-known-good edges plus explicit
provider health and staleness; it must never silently interpret unknown as
unblocked.

The OCC wave confirms the drift risk. Several issue bodies say `Depends on`
or `Blocks`, while the native GitHub graph omits those edges. OCC-10 #1026 says
it depends on six merged tickets but currently has no native blockers. Other
native edges diverged from the original planning table. A reproducible
breakdown workflow must publish and then validate the GitHub graph, not leave
dependencies only in prose.

## Recommended GitHub Model

This is the working recommendation pending user and design review.

### Build Order identity

Represent each Build Order as a normal root GitHub issue carrying one stable
`build-order` label. Its canonical technical identity is the GitHub global issue
node ID. Keep `owner/repo#number` as the human locator and the REST database ID
for relationship mutations; do not add a per-feature membership label.

This gives the selector a durable title, description, URL, open/closed state,
and discussion home. A constant discovery label finds root issues without
creating one repository label per feature.

### Membership

Make every implementation ticket a native GitHub sub-issue of the root. GitHub
supports listing, adding, removing, reprioritizing, and browsing sub-issues;
the REST relationship is machine-readable and the CLI exposes parent,
sub-issue, and completion-summary fields.

Use direct children as the v1 ticket set, limited to the configured tracker
repository and GitHub's 100 direct-child maximum. A ticket has one parent and
therefore one Build Order in v1. Cross-repository and nested orders require an
identity/model expansion rather than implicit support.

### Dependency edges

Use GitHub native issue dependencies as the only authoritative blocker syntax.
Issue-body `Depends on` text and planning-doc Mermaid edges are generated
projections for humans; `/aiur-build` must fail validation when either differs
from GitHub.

### Ticket metadata

Use existing GitHub fields directly:

| UI fact | GitHub source |
|---|---|
| Ticket ID, title, description, URL, timestamps | Issue fields |
| Workflow state | `agent:*` state label plus open/closed state |
| Complexity / points | `complexity:1` through `complexity:5` |
| Rollout phase | `phase:N` |
| Horizontal lane | `build-lane:documentation|frontend|backend|infrastructure` |
| Dispatch priority within a phase | `priority:N` when needed |
| Build Order membership | Native parent/sub-issue relationship |
| Blockers and dependents | Native issue dependency relationships |

Do not infer an authoritative phase solely from graph depth. The UI may show a
derived topological layer as a diagnostic, but `phase:N` is the planned rollout
source. Validation must reject a dependent whose phase is not later than its
open blocker and flag concurrent tickets with overlapping declared file or
contract surfaces.

## Recommended Aiur Runtime Overlay

Aiur should merge runtime facts through a typed tracker key and GitHub node-ID
mapping at the presentation boundary; a bare issue number is not sufficient:

| Runtime fact | Aiur source |
|---|---|
| Running, queued, retrying, paused, waiting reason | Orchestrator snapshot |
| CI and review state | Existing cached poller projection |
| Percent and ETA | `ticket.<id>.agent.progress*` events |
| Active CE phase | `ticket.<id>.agent.phase.<phase>.<start|end>` events |
| Latest activity and event evidence | Aiur event/workspace logs |
| Decision count and waiting-for-human state | Decision/subscription stores |

Progress and active phase currently live only inside
`src/lib/aiur/agent_list/event_intake.ex` and the TUI's in-memory AgentList
state. Build Order should extract that fold into one runtime-owned projection
consumed by both TUI and dashboard. The LiveView must not parse workspace logs
or maintain a second progress algorithm.

Closed GitHub tickets may render as complete even when their transient Aiur
progress sample is unavailable. For non-terminal tickets, missing or stale
Aiur progress must render as unknown/stale, never `0%`.

## State Management Shape

Use a provider composition model consistent with the current Control Center:

1. A GitHub Build Order provider discovers root issues, fetches direct
   sub-issues and native dependency edges, normalizes labels, and keeps a
   last-known-good snapshot with fetch timestamp and provider health.
2. A shared Aiur ticket-activity projection consumes progress, phase, and
   latest-event publications independently of LiveView and TUI lifecycles.
3. A Build Order presenter performs a pure join into nodes, edges, phases,
   critical-path/ready-state annotations, and aggregate counts.
4. LiveView subscribes to provider changes through PubSub and reads a bounded
   cached snapshot; the browser never polls GitHub directly.

Every node and edge should carry provenance and freshness. Partial GitHub
failure keeps the last-known-good graph visibly stale. Partial Aiur failure
keeps GitHub planning facts visible while runtime cells degrade to unknown.

## External References

- [GitHub planning with sub-issues and dependencies](https://docs.github.com/en/issues/tracking-your-work-with-issues/learning-about-issues/planning-and-tracking-work-for-your-team-or-project)
- [GitHub REST sub-issue endpoints](https://docs.github.com/en/rest/issues/sub-issues?apiVersion=2026-03-10)
- [GitHub REST issue-dependency endpoints](https://docs.github.com/en/rest/issues/issue-dependencies?apiVersion=2026-03-10)

## Remaining Research Work

- Resolve or convert the remaining questions in `questions.md` into explicit
  v1 decisions/gates.
- Write and review the requirements, implementation plan, issue-ready ticket
  contracts, structured graph, validation report, and Executor handoff.
