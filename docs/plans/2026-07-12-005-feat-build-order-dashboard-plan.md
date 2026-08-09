# Build Order Dashboard Implementation Plan

## Outcome

Ship an authenticated, GitHub-planning-read-only Build Order page that selects
one GitHub-rooted feature, renders its native dependency graph, overlays
current Aiur activity without changing planning truth, and remains truthful
through partial providers, cycles, restart and 100-ticket graphs.

The bounded feature is nineteen tickets (71 points). Twenty-five standalone
dashboard companions (87 points) align the current OCC with the refreshed
Units, Commands, controls and usage design, but do not enter the Build Order
root, critical path, ETA or terminal condition.

## Baselines

- Repository: `aiur-team/aiur`
- Researched code: `9849f32963c2a65367bce565b3f5ede3777c218f`
- Design HTML SHA-256:
  `23b527eade8c2fad7d37957c248be709091dfd112bbc6e13c6d76cd092d663a3`
- Design constraints SHA-256:
  `49e068d4999d62197dbd1d5c0438db21a25cd1b5873fb959a58a7e0388c7829a`
- Canonical baseline: `docs/build-order/build-order.json`
- Companion baseline and publication manifest:
  `docs/build-order/dashboard-companions.json` and
  `docs/build-order/publication.json`
- Capability audit: `docs/build-order/06-prototype-capability-audit.md`

Workers refresh current repository instructions, the configured integration
branch, active ownership seams, GitHub schema, layout-engine release and
provider protocols at pickup without silently weakening the ticket contract.
The current `.aiur/config` and `CONTRIBUTING.md` name `v2`, which does not
contain the researched OCC baseline on `main`; GATE-001 must
record a resolved integration branch/SHA before BO-004 or BO-008 is dispatched. The
bounded Executor skill gate is independent and must also be resolved first.

## Architecture

```text
BO-004 configured-repository identity -> BO-001 domain -> BO-002 fetch -> BO-003 LKG
              |                              |                              |
              +-> BO-017 observations -> BO-005 activity ------------------+-> BO-007 join
                                             |                                   |
                                             +-> BO-006 AgentList                |
              +-> BO-016 detail              +-> BO-019 history                 |
                         \                         /                               |
BO-008 browser harness ---> BO-018 accessible base context ----------------+-> BO-011 adapter
          |                    BO-001 + BO-008 -> BO-009 worker                    |
          |                    BO-008 + BO-009 -> BO-010 DOM/SVG -----------------+
          +---------------------------------------------------------------> BO-012 route
                                                                                |
                                                                          BO-013 interaction
                                                                                |
                                                                          BO-014 scale
                                                                                |
                                                    BO-006 ----------------> BO-015 acceptance
```

GitHub owns root/member identity, labels, lifecycle and native blockers. Aiur's
existing StatusReport owns execution/waiting/backend facts. BO-017 propagates
typed progress/stage/latest-evidence observations and BO-005 owns their shared
fold. BO-007 is a pure join. BO-016 owns configured-repository on-demand
detail, BO-019 owns bounded sanitized recent history, BO-018 composes the
accessible base context, and BO-011 adds selected-root relationship and
destination semantics. Server DOM owns semantics; the browser worker owns only
layout geometry. Cards receive bounded summaries; selected context reads
cached normalized providers rather than fetching per node or parsing logs.

## Build Order ticket graph

| ID | Outcome | Cx | Phase | Lane | Hard prerequisites |
|---|---|---:|---:|---|---|
| BO-001 | Strict domain/readiness contract | 3 | 1 | Backend | BO-004 |
| BO-002 | Complete bounded GitHub graph adapter | 4 | 2 | Backend | BO-001 |
| BO-003 | Atomic catalog/graph LKG | 4 | 3 | Backend | BO-002 |
| BO-004 | Configured-repository Issue/StatusReport identity | 3 | 1 | Infrastructure | — |
| BO-017 | Typed ticket observation propagation | 4 | 2 | Infrastructure | BO-004 |
| BO-005 | Shared daemon event activity | 4 | 3 | Backend | BO-017 |
| BO-006 | AgentList consumes shared activity | 3 | 4 | Frontend | BO-005 |
| BO-007 | Pure planning/runtime presenter | 4 | 4 | Backend | BO-001, BO-003, BO-005 |
| BO-008 | Browser/a11y/performance harness | 4 | 1 | Infrastructure | — |
| BO-009 | Pinned layout worker/static platform | 4 | 2 | Frontend | BO-001, BO-008 |
| BO-010 | DOM/SVG layout adapter and fallback | 4 | 3 | Frontend | BO-008, BO-009 |
| BO-011 | Build Order relationship/destination adapter | 4 | 4 | Frontend | BO-007, BO-018 |
| BO-012 | Selectable minimum graph route | 4 | 5 | Frontend | BO-003, BO-007, BO-010, BO-011 |
| BO-013 | Accessible graph interaction | 4 | 6 | Frontend | BO-008, BO-012 |
| BO-014 | Responsive redraw and bounded scale | 4 | 7 | Frontend | BO-008, BO-013 |
| BO-015 | Current-base acceptance capstone | 4 | 8 | Documentation | BO-006, BO-014 |
| BO-016 | Configured-repository ticket detail | 4 | 4 | Backend | BO-004 |
| BO-019 | Bounded sanitized recent ticket history | 3 | 4 | Backend | BO-005 |
| BO-018 | Accessible root-independent base context | 3 | 4 | Frontend | BO-008, BO-016, BO-019 |

BO-003, BO-005, BO-016, and BO-019 serialize wherever hard dependencies do not
already order their changes to the application-supervision surface. Phase is a
display/rollout hint, not a wave barrier. Same-phase hard edges are valid.

## Parallel execution shape

1. Resolve GATE-001 (integration baseline) and GATE-002 (Executor skill), then
   start BO-004 and BO-008 in parallel. The skill-delivery issue is a native
   blocker of both initial nodes.
2. BO-001, BO-017, and BO-016 follow identity. BO-002 follows BO-001; BO-005
   follows BO-017; BO-009 follows BO-001 and BO-008; BO-019 follows BO-005.
3. BO-003 follows BO-002; sequence every independently ready BO-003/005/016/019
   pair on the supervision seam and BO-005 with DASH-008 on
   observation-envelope consumption. BO-010 follows BO-008/009 while BO-018
   follows BO-008/016/019.
4. BO-006 follows activity; BO-007 follows activity and planning; BO-011 joins
   BO-018 base context to BO-007 relationship truth and destination capability.
5. BO-012 joins graph providers, presenter, layout and relationship context.
6. BO-013 owns relationship selection/accessibility and fit/pan/zoom semantics;
   BO-014 owns responsive transform preservation, redraw and measured
   20/50/100 scale.
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
  domains. The catalog defaults to 100 roots and explicit page/provider-call
  ceilings with overflow detection; selected roots remain bounded to 100
  members. One invalid root cannot hide the catalog.
- A complete adapter candidate has all pages/fields/endpoints. Provider error
  preserves stale LKG or shows unavailable; selected structural invalidity and
  member-local metadata warnings are separate states.
- Catalog and selected-root refresh defaults are 60 and 15 seconds. Selection
  or reconnect coalesces refresh when the demanded snapshot is older than 5
  seconds; healthy updates and stale LKG behavior are proven within bounds.
- Edge/readiness states are cleared, blocking, terminal-unsatisfied, unknown
  and cyclic, with conservative precedence. Only `CLOSED + COMPLETED` clears.

### Runtime and presentation

- Normalized issues and StatusReport gain configured-repository identity first;
  BO-017 then propagates it through versioned observations. Display strings and
  bare topics are never join keys. StatusReport keeps
  execution/waiting/backend ownership; BO-005 owns only
  progress/stage/latest cross-ticket event activity.
- Restart without replay makes open progress unknown, not zero.
- The presenter performs no I/O and preserves plan, dependency outcome,
  runtime state, agent stage and progress as separate fields.
- Build Order does not mutate GitHub planning or invoke mutating Aiur runtime
  actions in v1. Shared context may link to existing chat/Commands/control
  surfaces; companion tickets own any actionable capability and acknowledgement
  protocol.

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
| DASH-001 | Responsive URL-backed route shell | 3 | BO-008 |
| DASH-002 | Recoverable current-run membership | 4 | BO-017 |
| DASH-003 | Units filters/table/responsive UI | 3 | DASH-001, DASH-016, BO-018 |
| DASH-004 | Applied pause/resume protocol | 4 | BO-004 |
| DASH-005 | Unit and capacity controls UI | 3 | DASH-003, DASH-004 |
| DASH-006 | Retained Decision lookup/query | 3 | — |
| DASH-007 | Commands presentation catch-up | 3 | DASH-001, DASH-006, DASH-017 |
| DASH-008 | Raw usage plus versioned token relationships | 4 | BO-017, DASH-018 |
| DASH-009 | Durable usage ledger and delta checkpoints | 4 | DASH-008 |
| DASH-010 | Claude additive Remote Control usage adapter | 3 | DASH-008, DASH-019 |
| DASH-011 | Relationship-aware cost/grouping projection | 4 | DASH-024 |
| DASH-012 | Provider-meter foundation | 3 | DASH-018 |
| DASH-013 | Claude subscription/API meter adapter | 4 | DASH-012; named human protocol gate |
| DASH-014 | Canonical current-run summary | 4 | DASH-016 |
| DASH-015 | Authenticated usage/provider UI | 4 | DASH-003, DASH-010, DASH-011, DASH-013, DASH-020, DASH-021, DASH-025 |
| DASH-016 | Units row/filter/URL policy | 3 | DASH-002, BO-005 |
| DASH-017 | Trusted Decision provenance/confidence | 3 | — |
| DASH-018 | Opaque provider-account generation | 3 | — |
| DASH-019 | Authenticated local Claude telemetry transport | 4 | BO-004; named human protocol gate |
| DASH-020 | Codex provider-meter adapter | 3 | DASH-012 |
| DASH-021 | Enforced financial-data boundary | 3 | DASH-001 |
| DASH-022 | Accessible nonfinancial run-summary UI | 3 | DASH-003, DASH-014 |
| DASH-023 | Selected-Build-Order usage integration | 4 | BO-003, BO-012, DASH-011, DASH-015, DASH-021 |
| DASH-024 | Crash-safe aggregate/query projection | 4 | DASH-009 |
| DASH-025 | Dimension-preserving retention/compaction | 4 | DASH-024 |

These dependencies publish as native GitHub blockers even though companions
have no Build Order parent. DASH-018 owns the single opaque, privacy-safe
provider-account generation shared by usage and meters. DASH-008 serializes
with BO-005 on event ingestion, consumes BO-017 identity, and owns the
versioned per-provider/source token-relationship contract. DASH-010 pins Claude
base input, cache creation, and cache read as additive request dimensions for
the exact supported telemetry revision. DASH-009 owns the append/checkpoint
authority and preserves that pinned revision unchanged through canonical
records and replayed deltas. DASH-024 owns bounded aggregate/query snapshots
partitioned by revision, and DASH-025 owns destructive
rotation/retention/compaction without merging revisions while preserving every
grouping and downstream pricing dimension. DASH-011
prices and reconciles those qualified dimensions separately, including Claude
additive and Codex-subset behavior, and fails closed when the relationship is
unknown or contradictory;
DASH-011 also reconciles compatible-currency API-equivalent contributors into
one cross-provider/cross-generation run or build estimate while preserving the
groups and never mixing bases or currencies.
DASH-015 alone joins them to DASH-020/013 tier facts by an exact known
provider/backend/generation match. DASH-001 consumes BO-008's shared real-route
browser harness and serializes with BO-012 on route/navigation registration.
DASH-003 consumes BO-018's root-independent base context;
BO-011 remains Build Order-specific. DASH-006 and DASH-017 serialize on
Decision storage while remaining independently acceptable. DASH-019 owns the
local trust/correlation boundary; it and DASH-004 depend on BO-004 identity,
and DASH-018/019 serialize on the Claude lifecycle adapter. DASH-010 only
normalizes accepted requests.
DASH-002/009/012/018/019/024/025 and BO-003/005/016/019 introduce long-lived
services through the central application supervision tree. The companion graph
therefore declares every independently ready same-pack and cross-pack
serialization pair; existing hard dependencies order the remaining pairs.
DASH-023 alone maps the selected root's current membership generation into
retained usage scope without entering Build Order completion and serializes
with BO-013/014 on Build Order route component work.
DASH-001/003/005/007/015/022/023 and BO-012..014 touch shared dashboard composition
or CSS and must be sequenced/rebased. Companion publication receives complexity and
`model:codex`, never phase/lane/root membership or `agent:todo`.
All twenty-five companions also carry the non-native
`GATE-OCC-PREDECESSOR-BASELINE`; closed #1034 is accepted evidence within that
gate rather than an active native blocker.

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

### Capstone/Executor

- Reconcile every member, label and native blocker from GitHub.
- Prove the real published root plus synthetic cycle/invalid/degraded/scale
  fixtures; the real root alone cannot cover every failure mode.
- From the Executor repository root, run the real CLI and TUI workflow required by
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
