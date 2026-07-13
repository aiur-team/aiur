# Build Order Technical Decisions

This registry is the concise decision authority for plan version 1. Detailed
rationale and failure semantics live in
[03-source-of-truth-and-state.md](03-source-of-truth-and-state.md). The
structured copies in `build-order.json` are validated against ticket usage.

## DEC-001 — Split GitHub plan from Aiur activity

**Status:** accepted

GitHub owns identity, membership, ticket facts, lifecycle, planning labels, and
native blocker relationships. Aiur owns current execution activity, progress,
alerts, and events. A pure presenter joins snapshots without changing either
authority.

## DEC-002 — Use root issue membership

**Status:** accepted for the v1 planning baseline

Discover root issues by one `build-order` label and use their direct native
sub-issues as members. Canonical identity is the GitHub node ID. V1 is limited
to the configured repository, direct children, one parent, and 100 members.
The user may expand this only by resolving the recorded product gate before
issue dispatch.

## DEC-003 — Use native blockedBy only

**Status:** accepted

Native GitHub `blockedBy` is the only hard dependency truth. Body tables and
planning diagrams are generated views. Only a blocker closed with the completed
state reason clears its edge; `NOT_PLANNED`, missing, stale, cyclic, and unknown
relationships remain unsatisfied or unknown.

## DEC-004 — Keep planning metadata single-valued

**Status:** accepted

Each member has exactly one complexity, positive phase, and controlled lane
label. A small hidden marker binds logical ID and plan version to the immutable
approved planning commit, but it may not duplicate membership, dependencies,
lifecycle, progress, live state, or mutable provenance.

## DEC-005 — Publish complete graph generations

**Status:** accepted

A daemon-owned supervised projection performs paginated GitHub reads, validates
the whole candidate, and swaps it atomically. Failures preserve a stale
last-known-good snapshot or report unavailable. LiveView never polls GitHub.

## DEC-006 — Extract runtime projection from UI ownership

**Status:** accepted

Add repository-qualified identity to normalized issues and existing
orchestrator StatusReport records; StatusReport remains the owner of execution,
waiting, backend/model, and worker-lifecycle state. Move only the reusable
progress, active-stage, and latest cross-ticket event fold out of interactive
AgentList into an always-supervised typed-identity projection. TUI and dashboard
join the two typed snapshots. Restart without replay yields unknown progress
rather than zero and never creates a second lifecycle owner.

## DEC-007 — Use an isolated layout-only engine

**Status:** accepted

Keep cards as accessible DOM and edges as SVG. Begin with pinned, vendored
ELK.js layered layout behind one LiveView hook/adapter and run it in a Web
Worker at scale. The adapter owns lane/phase constraints, layout inputs,
geometry application, a transform seam, redraw, and deterministic failure
fallback. BO-013 exclusively owns fit/pan/zoom interaction policy and controls;
BO-014 owns responsive preservation and measured hardening. ELK does not own
product state or rendering.

This choice follows ELK's documented strength for directed layered graphs,
routed edges, and Web Worker operation. BO-008 establishes the browser harness,
BO-009 owns reproducible vendoring/worker packaging, BO-010 owns the measured
DOM/SVG adapter and fallback, and BO-014 proves representative 20/50/100
fixtures. If the engine fails the accepted budget, the owning ticket records
the evidence and substitutes a maintained layout-only engine without changing
the adapter contract.

## DEC-008 — Keep v1 read-only

**Status:** accepted for the v1 planning baseline

Build Order does not mutate GitHub planning data. It inherits dashboard
authentication and safe URL rules and invokes no mutating Aiur runtime action
in v1. It may link into existing chat, Commands, and control surfaces.
Companion components may adopt the reusable context and add actions only
through their separately owned capability, confirmation, and
applied-acknowledgement contracts. Dependency editing is a separately
authorized feature.

## DEC-009 — Keep companion dashboard work separate

**Status:** accepted

Responsive shell, Units catalog/presentation, runtime control protocol/UI,
Decision provenance/Commands, usage envelope/ledger/Remote Control accounting,
cost projection, provider meters, run summary and usage UI are fifteen
companion tickets. They do not enter the Build Order root or terminal condition.
BO-011 owns reusable ticket context; BO-012 consumes the shared route contract
when available without waiting for all companion metrics.

## DEC-010 — Treat phase as a hint

**Status:** accepted

Phase controls presentation and rollout grouping only. Readiness comes from
native dependencies, current lifecycle, data health, conflicts, and capacity.

## DEC-011 — Materialize without dispatch

**Status:** accepted

After user review, publish the approved GitHub issues with exactly one
`complexity:N` and `model:codex` on executable work. Do not apply `agent:todo`,
start Aiur, or otherwise dispatch a ticket during planning.

## DEC-012 — Protect the finite boundary

**Status:** accepted

During later execution, P0/P1 acceptance blockers may be promoted, contained
review findings return to their existing ticket, and non-blocking defects or
optimizations go to the deferred ledger. Freeze promotion when created or
promoted work outpaces completed critical-path work.

## DEC-013 — Gate execution on the real baseline

**Status:** accepted

Planning evidence is pinned to the completed Operator Control Center work on
`main`, while the current repository config and contribution policy still name
the divergent `v2` integration branch. No Build Order ticket may be dispatched
until a human records the configured branch/SHA that contains the accepted OCC
baseline and the predecessor dashboard run is complete. That baseline gate
applies to both Build Order and every standalone dashboard companion. Build
Order execution is additionally gated on the bounded `/aiur-run` revision from
PR #1065 commit `0daf2972` (or an explicitly reviewed compatible successor)
being installed and discoverable. These are external pre-dispatch gates, not
feature tickets or additions to the completion denominator.

## Rejected alternatives

- A draft planning PR as the live graph database: it drifts from GitHub and
  Aiur.
- One label per Build Order on every member: it duplicates native parenthood.
- Per-browser or per-node GitHub polling: it scales with viewers/nodes and can
  silently clear failed dependency reads.
- A canvas-only graph: it makes rich accessible ticket cards and focus
  behavior materially harder.
- Progress-based dependency completion: it contradicts GitHub lifecycle truth.
- The prototype's deterministic fixed SVG coordinates as production layout:
  they are illustrative and do not meet arbitrary graph/viewport constraints.
