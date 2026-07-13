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
The operator may expand this only by resolving the recorded product gate before
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
label. A small hidden marker may preserve logical ID and provenance, but it may
not duplicate membership, dependencies, lifecycle, progress, or live state.

## DEC-005 — Publish complete graph generations

**Status:** accepted

A daemon-owned supervised projection performs paginated GitHub reads, validates
the whole candidate, and swaps it atomically. Failures preserve a stale
last-known-good snapshot or report unavailable. LiveView never polls GitHub.

## DEC-006 — Extract runtime projection from UI ownership

**Status:** accepted

Move the reusable activity fold out of the interactive AgentList into an
always-supervised typed-identity projection. TUI and dashboard consume it.
Restart without replay yields unknown progress rather than zero.

## DEC-007 — Use an isolated layout-only engine

**Status:** accepted

Keep cards as accessible DOM and edges as SVG. Begin with pinned, vendored
ELK.js layered layout behind one LiveView hook/adapter and run it in a Web
Worker at scale. The adapter owns lane/phase constraints, layout inputs,
redraw, fit/pan/zoom, and a deterministic failure fallback; ELK does not own
product state or rendering.

This choice follows ELK's documented strength for directed layered graphs,
routed edges, and Web Worker operation. BO-006 must prove the representative
20/50/100 fixtures before the route depends on it. If that proof fails, the
ticket records the evidence and substitutes a maintained layout-only engine
without changing the adapter contract.

## DEC-008 — Keep v1 read-only

**Status:** accepted for the v1 planning baseline

Build Order does not mutate GitHub. It inherits dashboard authentication and
safe URL rules. Dependency editing is a separately authorized feature if the
operator rejects this baseline before dispatch.

## DEC-009 — Keep companion dashboard work separate

**Status:** accepted

Responsive shell, Units read model, unit/capacity controls, Commands, durable
usage observations, accounting projection, account meters, and usage summary
are eight companion tickets. They do not enter the Build Order root or terminal
condition. BO-008 owns reusable ticket context; BO-009 consumes the shared route
contract when available without waiting for all companion metrics.

## DEC-010 — Treat phase as a hint

**Status:** accepted

Phase controls presentation and rollout grouping only. Readiness comes from
native dependencies, current lifecycle, data health, conflicts, and capacity.

## DEC-011 — Materialize without dispatch

**Status:** accepted

After operator review, publish the approved GitHub issues with exactly one
`complexity:N` and `model:codex` on executable work. Do not apply `agent:todo`,
start Aiur, or otherwise dispatch a ticket during planning.

## DEC-012 — Protect the finite boundary

**Status:** accepted

During later execution, P0/P1 acceptance blockers may be promoted, contained
review findings return to their existing ticket, and non-blocking defects or
optimizations go to the deferred ledger. Freeze promotion when created or
promoted work outpaces completed critical-path work.

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
