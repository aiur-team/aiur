# Build Order Dashboard Implementation Plan

## Outcome

Ship an authenticated, GitHub-planning-read-only Build Order page that selects
one GitHub-rooted feature, renders its native dependency graph, overlays
current Aiur activity without changing planning truth, and remains truthful
through partial providers, cycles, restart and 100-ticket graphs.

The bounded feature is fifteen tickets (57 points). Fifteen standalone
dashboard companions (56 points) align the current OCC with the refreshed
Units, Commands, controls and usage design, but do not enter the Build Order
root, critical path, ETA or terminal condition.

## Baselines

- Repository: `its-everdred/aiur`
- Researched code: `b7c4e7c06b8c7011f306ce9efb0b9cd8fd8cbac5`
- Design HTML SHA-256:
  `23b527eade8c2fad7d37957c248be709091dfd112bbc6e13c6d76cd092d663a3`
- Design constraints SHA-256:
  `49e068d4999d62197dbd1d5c0438db21a25cd1b5873fb959a58a7e0388c7829a`
- Canonical baseline: `docs/build-order/build-order.json`
- Capability audit: `docs/build-order/06-prototype-capability-audit.md`

Workers refresh current repository instructions, the configured integration
branch, active ownership seams, GitHub schema, layout-engine release and
provider protocols at pickup without silently weakening the ticket contract.

## Architecture

```text
GitHub GraphQL -> BO-002 adapter -> BO-003 catalog/selected-root LKG --+
                                                                    |
Aiur lifecycle -> BO-004 typed identity -> BO-005 activity ----------+-> BO-007 presenter
                                           |                               |
                                           +-> BO-006 AgentList            +-> BO-011 context
                                                                               |
BO-008 browser harness -> BO-009 assets/worker -> BO-010 DOM/SVG adapter -------+
                                                                               v
                                                                         BO-012 route
                                                                               |
                                                                         BO-013 interaction
                                                                               |
                                                                         BO-014 scale
                                                                               |
                                                                         BO-015 acceptance
```

GitHub owns root/member identity, labels, lifecycle and native blockers. Aiur
owns activity and progress. BO-007 is a pure join. Server DOM owns semantics;
the browser worker owns only layout geometry. Cards receive bounded summaries;
selected context reads cached normalized detail rather than fetching per node.

## Build Order ticket graph

| ID | Outcome | Cx | Phase | Lane | Hard prerequisites |
|---|---|---:|---:|---|---|
| BO-001 | Strict domain/readiness contract | 3 | 1 | Backend | — |
| BO-002 | Complete bounded GitHub graph adapter | 4 | 2 | Backend | BO-001 |
| BO-003 | Atomic root catalog and selected LKG | 4 | 3 | Backend | BO-002 |
| BO-004 | Repository-qualified event identity | 4 | 2 | Infrastructure | BO-001 |
| BO-005 | Shared daemon ticket activity | 4 | 3 | Backend | BO-004 |
| BO-006 | AgentList consumes shared activity | 3 | 4 | Frontend | BO-005 |
| BO-007 | Pure planning/runtime presenter | 4 | 4 | Backend | BO-001, BO-005 |
| BO-008 | Browser/a11y/performance harness | 3 | 1 | Infrastructure | — |
| BO-009 | Pinned layout worker/static platform | 4 | 2 | Frontend | BO-001 |
| BO-010 | DOM/SVG layout adapter and fallback | 4 | 3 | Frontend | BO-008, BO-009 |
| BO-011 | Reusable all-state ticket context | 4 | 4 | Frontend | BO-007 |
| BO-012 | Selectable minimum graph route | 4 | 5 | Frontend | BO-003, BO-007, BO-010, BO-011 |
| BO-013 | Accessible graph interaction | 4 | 6 | Frontend | BO-008, BO-012 |
| BO-014 | Responsive redraw and bounded scale | 4 | 7 | Frontend | BO-008, BO-013 |
| BO-015 | Current-base acceptance capstone | 4 | 8 | Documentation | BO-006, BO-014 |

BO-003 and BO-005 serialize because both change the application supervision
surface after different prerequisites. Phase is a display/rollout hint, not a
wave barrier. Same-phase hard edges are valid.

## Parallel execution shape

1. BO-001 and BO-008 can begin together.
2. After BO-001, start BO-002, BO-004 and BO-009 independently.
3. BO-003 follows BO-002; BO-005 follows BO-004. Sequence those two on the
   supervision seam, while BO-010 follows BO-008/009 in parallel.
4. BO-006 and BO-007 follow activity; BO-011 follows the presenter.
5. BO-012 joins graph providers, presenter, layout and context.
6. BO-013 owns relationship selection/accessibility; BO-014 owns pan/zoom,
   responsive redraw and measured 20/50/100 scale.
7. BO-015 integrates current base, proves the published root and closes it only
   after post-merge real workflow evidence.

The Executor maximizes progress against ready critical-path work, not raw agent
count. Companion work may use spare capacity only under separate authorization
and cannot displace the feature path.

## Core contracts

### Planning and provider health

- Canonical identity is repository plus GitHub node ID; number is a URL/display
  locator.
- Root catalog and selected graph are separate operations and LKG health
  domains. One invalid root cannot hide the catalog.
- A complete adapter candidate has all pages/fields/endpoints. Provider error
  preserves stale LKG or shows unavailable; selected structural invalidity and
  member-local metadata warnings are separate states.
- Edge/readiness states are cleared, blocking, terminal-unsatisfied, unknown
  and cyclic, with conservative precedence. Only `CLOSED + COMPLETED` clears.

### Runtime and presentation

- Event identity is repository-qualified at trusted ingestion; display strings
  and bare topics are never join keys.
- Restart without replay makes open progress unknown, not zero.
- The presenter performs no I/O and preserves plan, dependency outcome,
  runtime state, agent stage and progress as separate fields.
- Build Order does not mutate GitHub planning. Shared ticket context may expose
  existing Aiur actions only through authenticated writable/capability,
  confirmation and applied acknowledgement.

### Browser

- Routes are `/build-orders` and `/build-orders/:root_number`; URL selection is
  deterministic across share/back/refresh.
- The engine is pinned, licensed, checksummed and served locally. Worker
  generations are cancellable/stale-safe; product state never enters it.
- DOM order stays semantic. Layout failure keeps a readable fallback.
- Interaction is keyboard/pointer/touch complete; pan/zoom/fit controls are
  named; focus, reduced motion, mobile safe area and 200% reflow are proven.

## Standalone dashboard companions

| ID | Outcome | Cx | Hard prerequisites |
|---|---|---:|---|
| DASH-001 | Responsive URL-backed route shell | 3 | sequence after #1034 |
| DASH-002 | Current-run Units catalog/predicates | 4 | BO-005 |
| DASH-003 | Units filters/table/responsive UI | 3 | DASH-001, DASH-002, BO-011 |
| DASH-004 | Applied pause/resume protocol | 4 | — |
| DASH-005 | Unit and capacity controls UI | 3 | DASH-002, DASH-003, DASH-004 |
| DASH-006 | Decision lookup/provenance contract | 4 | — |
| DASH-007 | Commands presentation catch-up | 3 | DASH-001, DASH-006 |
| DASH-008 | Provider-neutral usage envelope | 4 | BO-004 |
| DASH-009 | Durable attributed usage ledger | 4 | DASH-008 |
| DASH-010 | Claude Remote Control usage adapter | 4 | DASH-008; sibling protocol gate if required |
| DASH-011 | Versioned cost/grouping projection | 4 | DASH-009 |
| DASH-012 | Meter contract and Codex adapter | 4 | — |
| DASH-013 | Claude subscription/API meter adapter | 4 | DASH-012; sibling protocol gate if required |
| DASH-014 | Canonical current-run summary | 4 | DASH-002 |
| DASH-015 | Accessible usage/run summary UI | 4 | DASH-001, DASH-003, DASH-010..014 |

These dependencies publish as native GitHub blockers even though companions
have no Build Order parent. DASH-008 serializes with BO-005 on event ingestion.
DASH-001/003/005/007/015 and BO-012..014 touch shared dashboard composition or
CSS and must be sequenced/rebased. DASH-006 and BO-004 coordinate provenance
schema boundaries. Companion publication receives complexity and
`model:codex`, never phase/lane/root membership or `agent:todo`.

## Verification

### Agent-runnable

- pure parser/readiness/presenter tables;
- paginated GitHub partial/error/cycle/external fixtures and call bounds;
- OTP projection/LKG/PubSub/restart/coalescing tests without sleeps;
- AgentList compatibility characterization;
- static-asset worker/hook and real browser harness tests;
- keyboard/touch/focus/reduced-motion/200%-zoom/mobile-safe-area checks;
- 20/50/100-member generation/routing/performance fixtures with numeric budgets;
- current repository compile, format, lint/spec, coverage and CI gates.

### Capstone/operator

- Reconcile every member, label and native blocker from GitHub.
- Prove the real published root plus synthetic cycle/invalid/degraded/scale
  fixtures; the real root alone cannot cover every failure mode.
- From the operator repo root, run the real CLI and TUI workflow required by
  `AGENTS.md`, plus authenticated browser selection/context/live updates.
- Verify existing Units, Commands, Analytics and TUI remain intact on the
  current configured integration branch and after merge.

## Convergence policy

Promote only an independent P0/P1 acceptance blocker. Contained findings return
to the same ticket. P2/P3 defects and optimizations retain evidence in
`deferred-findings.md` without changing feature count/ETA/capacity. Freeze new
promotion when creation exceeds completion. The loop stops after BO-015 proves
implementation, review, current-base CI, merge, documentation, cleanup and the
required end-to-end workflow—not after every discovered improvement is fixed.

## Planning gate

The final planning action is GitHub materialization and reconciliation. It does
not launch Aiur, merge either planning branch, or add an active agent label.
