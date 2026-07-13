# Build Order Dashboard Implementation Plan

## Outcome

Ship an authenticated, read-only Build Order dashboard that selects one
GitHub-rooted feature plan, renders its native dependency graph, overlays
current Aiur activity without changing planning truth, and remains truthful
through partial providers, cycles, external blockers, restart, and 100-ticket
graphs.

This plan covers 11 Build Order implementation tickets (40 complexity points).
Eight standalone dashboard companions (29 points) align the refreshed shell,
Units, Commands, controls, and usage/accounting but are outside the Build Order
root, critical path, ETA, and terminal condition.

## Baselines

- Repository: `its-everdred/aiur`
- Researched code: `3d67b7be722eb649f28088fc8d609dd7b75254c7`
- Design HTML SHA-256:
  `23b527eade8c2fad7d37957c248be709091dfd112bbc6e13c6d76cd092d663a3`
- Design constraints SHA-256:
  `49e068d4999d62197dbd1d5c0438db21a25cd1b5873fb959a58a7e0388c7829a`
- Canonical graph: `docs/build-order/build-order.json`
- Requirements:
  `docs/brainstorms/2026-07-12-build-order-requirements.md`

Workers must refresh current paths, active dashboard PRs, GitHub schema, ELK.js
release, and current integration-branch instructions at pickup without silently
changing the ticket contract.

## Architecture

```text
GitHub GraphQL
      |
      v
BO-002 complete adapter
      |
      v
BO-003 catalog + selected-root LKG ----+
                                      |
Aiur events -> BO-004 activity -------+--> BO-006 pure presenter
                  |                              |
                  +--> BO-005 AgentList          +--> BO-008 ticket context
                                                     |
BO-007 layout worker -------------------------------+
                                                     v
                                               BO-009 route/MVS
                                                     |
                                                     v
                                               BO-010 hardening
                                                     |
                                                     v
                                               BO-011 acceptance
```

GitHub owns root/member identity, labels, lifecycle, and native `blockedBy`.
Aiur owns activity, progress, alerts, and events. BO-006 is the only join and
does no I/O. Server-rendered DOM owns semantics; the BO-007 browser worker owns
geometry and edge routing only.

## Ticket graph

| ID | Outcome | Cx | Phase | Hard prerequisites |
|---|---|---:|---:|---|
| BO-001 | Strict Build Order domain contract | 3 | 1 | — |
| BO-002 | Complete bounded GitHub graph adapter | 4 | 2 | BO-001 |
| BO-003 | Atomic catalog/order LKG projections | 4 | 3 | BO-002 |
| BO-004 | Shared headless ticket activity | 4 | 2 | BO-001 |
| BO-005 | AgentList consumes shared activity | 3 | 3 | BO-004 |
| BO-006 | Pure planning/runtime presenter | 3 | 3 | BO-001, BO-004 |
| BO-007 | Vendored accessible layout platform | 4 | 2 | BO-001 |
| BO-008 | Reusable all-state ticket context | 3 | 4 | BO-006 |
| BO-009 | Selectable minimum graph route | 4 | 5 | BO-003, BO-006, BO-007, BO-008 |
| BO-010 | Interaction/a11y/scale hardening | 4 | 6 | BO-009 |
| BO-011 | Merged-base real-workflow capstone | 4 | 7 | BO-005, BO-010 |

BO-003 and BO-004 are symmetric `serializes_with` because both change the
application supervision tree and its tests. Phase is a presentation/rollout
hint, not a wave barrier; the later Executor derives readiness from hard edges,
this conflict, tracker state, and capacity.

## Parallel execution shape

1. Land BO-001 first to avoid competing identity and state contracts.
2. Start BO-002, BO-004, and BO-007 in parallel.
3. Once BO-004 completes, BO-003, BO-005, and BO-006 may run in parallel; if
   BO-004 is still active when BO-002 completes, BO-003 waits on the declared
   supervision conflict.
4. Start BO-008 after BO-006. BO-005 may continue independently.
5. Start BO-009 only after BO-003, BO-006, BO-007, and BO-008 are merged.
6. BO-010 hardens the real page; BO-011 integrates and proves the bounded
   feature after both the page and AgentList migration are complete.

The Executor maximizes progress against this graph, not raw agent count. It may
use standalone companion work to fill spare capacity only under separate
authorization and without displacing the Build Order critical path.

## Implementation contracts by layer

### Domain and GitHub provider

- Canonical identity is repository plus GitHub node ID; issue number remains a
  mutable URL/display locator.
- Root catalog and selected-root graph are separate provider operations and
  separate LKG health domains.
- A successful adapter candidate is complete. Any page/field GraphQL error,
  count mismatch, malformed identity, or over-limit membership fails the
  candidate.
- Optional malformed body markers create diagnostics but do not erase a valid
  GitHub issue.
- Only `CLOSED + COMPLETED` satisfies a native blocker.

### Runtime and presentation

- Ticket activity is keyed by tracker kind, project/repository identity, and
  issue identity; bare numbers are prohibited.
- Activity carries observed time/source/staleness. Restart without replay makes
  open-ticket progress unknown.
- Presenter precedence is GitHub terminal outcome, runtime overlay, dependency
  readiness, then planned phase/lane. These remain separate fields.
- Cycles, external blockers, conflicting labels, and unavailable providers are
  explicit diagnostics, not filtered rows.

### Browser and LiveView

- Routes are `/build-orders` and `/build-orders/:root_number`; the selected
  route is canonical and survives share/back/refresh.
- Cards remain semantic server-rendered controls. ELK.js is pinned and served
  locally; a generation-safe worker returns coordinates/routes only.
- Build Order is read-only and works under authenticated dashboard read-only
  mode. No GitHub mutation or editing event exists.
- Hook failure keeps a readable fallback. Unknown provider/progress state never
  renders as empty, ready, or zero.

## Companion dashboard plan

| ID | Standalone outcome | Cx | Dependency |
|---|---|---:|---|
| DASH-001 | Responsive URL-backed shell/navigation | 3 | — |
| DASH-002 | Units all-state read model and filters | 4 | — |
| DASH-003 | Unit pause/resume and capacity controls | 4 | DASH-002 |
| DASH-004 | Commands presentation parity | 3 | — |
| DASH-005 | Durable attributed usage observations | 4 | — |
| DASH-006 | Cost/coverage/grouping projection | 4 | DASH-005 |
| DASH-007 | Provider account meter projection | 4 | — |
| DASH-008 | Shared run/build summary UI | 3 | DASH-006, DASH-007 |

These tickets have their own contracts under
`docs/build-order/companion-tickets/`. They receive complexity and
`model:codex`, but no `phase:N`, `build-lane:*`, or Build Order parent unless a
future planning run explicitly creates a separate order.

Shared-write guidance:

- DASH-001 owns shared shell/navigation/CSS. BO-009 only registers its route.
- BO-008 owns ticket context. DASH-002 consumes it rather than creating another
  modal contract.
- DASH-002, DASH-003, DASH-004, DASH-008, and BO-009 must rebase/sequence shared
  `DashboardLive` and CSS work rather than editing the same composition in
  parallel.
- DASH-005 and DASH-007 may run in parallel; DASH-006 follows observations and
  DASH-008 joins accounting plus meters.

## Verification strategy

### Agent-runnable

- Pure domain/parser/presenter policy tables.
- Synthetic GitHub GraphQL pagination, partial-error, external-reference, and
  call-bound fixtures.
- OTP projection, LKG, coalescing, restart, PubSub, retention, and supervision
  tests without sleeps.
- AgentList characterization and compatibility tests.
- Static asset/worker/hook, LiveView route/state, component, accessibility, and
  browser tests.
- 20/50/100 node performance fixtures with recorded budgets.
- Repository compile, formatting, specs/lint, coverage, regression, dialyzer,
  and `make ci` gates required by current `CONTRIBUTING.md`.

### At merge and operator root

- Reconcile current base and every active dashboard ownership seam.
- Requery the published GitHub root, direct membership, labels, and every
  native blocker relationship.
- From the operator repo root, run the real CLI workflow required by
  `AGENTS.md`; an issue workspace must not bypass its `--test` guard.
- Observe the authenticated browser route plus required TUI evidence for root
  selection/deep links, live activity, LKG degradation, contexts, keyboard,
  touch, theme, reduced motion, narrow viewport, and 20/50/100 fixtures.

## Finite boundary and discovery policy

- P0/P1 findings that directly block a requirement, CI, merge, daemon operation,
  or required end-to-end proof may be promoted.
- A review finding inside a ticket's acceptance returns that ticket to rework.
- P2/P3 defects and optimizations go to
  `docs/build-order/deferred-findings.md` with evidence and do not change the
  feature denominator or ETA.
- If created/promoted work outpaces completions in an Executor interval, freeze
  new promotion until the original feature completes.
- The loop stops after implementation, review, current-base green, merge,
  documentation, cleanup, and real end-to-end proof—not after every discovery
  is exhausted.

## Open gates

- Confirm same-configured-repository and read-only v1 before dispatch.
- Resolve subscription cost display, Build Order usage time window, and direct
  Claude Remote Control coverage before the affected standalone usage tickets.
- Operator reviews this ticket pack before GitHub materialization. Publication
  adds no `agent:todo` and does not start Aiur.
