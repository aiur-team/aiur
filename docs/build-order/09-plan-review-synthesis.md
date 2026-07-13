# Plan review synthesis

Current semantic review of the consolidated planning pack at 20 BO + 34 DASH
members. This document supersedes the pre-consolidation 19 BO / 53-ticket
review narrative; historical recommendations are not execution authority.

## Current verdict

The 54-member decomposition is coherent and mechanically reproducible: one
root owns every member, 105 internal dependencies are acyclic and resolved,
and two external skill blockers produce the exact 107-relation publication
graph across 56 issues. The accounting family remains in scope, Analytics
remains excluded, and all member documents use the exact Sol routing label.

Worker readiness is covered by `08-implementation-pointers.md`, which now has
exactly one grounded section for every manifest member, including BO-020. The
canonical validator checks this one-to-one coverage whenever a planning pack
supplies that pointer map. `07-graph-parallelism-review.md` is the active
54-member wave and serialization analysis.

The planning pack may proceed through final immutable review once its local
validators and suites are clean. Execution remains blocked by GATE-002:
PR #1065 must be finally reviewed, merged, and recorded by its exact successor
or merge SHA. `27ba3c44` is only the minimum multi-prefix ancestry marker; it
does not authorize execution, and neither does the current draft head.

## Contract reconciliation

- Publication boundary: root + 54 members + SKILL-DELIVERY-001 = 56 issues.
- Hard blockers: 105 manifest dependencies + two external skill blockers =
  107 native `blockedBy` relations.
- Membership: BO-001..BO-020 and DASH-001..DASH-034 are direct children of the
  single root; the skill issue remains standalone.
- Receipts: core v3 owns root/member identity, bodies, labels, states, and graph;
  auxiliary v2 owns the standalone skill issue, external blockers, and unique
  reconciliation comment. Both are required.
- Labels: each member has exactly one routing label,
  `model:codex-gpt-5.6-terra`; generic Codex, Sol, Luna, Claude, and additional
  model labels are forbidden.
- Scope: no issue publication has occurred. Read-only predecessor issues and
  unrelated PRs remain outside the mutable boundary.

## Review findings resolved in this revision

1. BO-020 now has a concrete pointer section tied to BO-003/BO-007 data,
   BO-012's route, existing component/table conventions, the committed visual
   reference, and the BO-008 browser harness.
2. The read-first graph and synthesis documents now describe the consolidated
   54-member contract rather than the retired 53-ticket draft.
3. Receipt materialization now shares one safe-path policy and enforces finite
   file-count, per-file, aggregate-byte, and Git-process limits before writing
   immutable receipt content.
4. Live GitHub verification now shares one finite request/item budget across
   every endpoint and both stability snapshots; endpoint and snapshot
   boundaries cannot reset it.

## Remaining operator/start-gate decisions

- Resolve and merge PR #1065, then record its exact final SHA and prove it
  descends from `27ba3c44` before dispatch.
- Decide the publication ceremony scope, any ticket-merge candidates, and any
  structural-parallelism changes before approving a changed receipt. Until
  explicitly adopted, none alters this graph.
- Name the authorized `/aiur-build` verification owner and obtain explicit run
  authorization after GATE-001 and GATE-002 are proven live.

## Non-authoritative historical note

The earlier nine-lens review was performed before single-root consolidation.
It correctly identified the need for implementation pointers, graph-wave
analysis, and explicit product decisions, but its 19 BO / 53-ticket counts,
retired companion manifest worklist, partial-pointer status, and old skill pins
are obsolete. They must not be used for publication or execution.
