# Reproducible Feature-Decomposition Patterns

This synthesis comes from document reviews of:

- `ethereum-optimism/actions` PR #513;
- `aiur-team/aiur` PR #732; and
- `aiur-team/aiur` PR #971.

The reusable workflow is a traceable funnel:

```text
intake and identity
  -> requirements and decisions
  -> repository/design evidence
  -> cumulative synthesis
  -> adversarial verification
  -> worker-sized ticket contracts
  -> validated typed graph
  -> optional GitHub materialization
  -> runtime Executor handoff
```

## What consistently worked

1. Requirements and product decisions existed before ticket boundaries.
2. Current code, tests, issues, PRs, and subsystem owners constrained the
   architecture before new storage or services were proposed.
3. Brief, evidence, decisions/contracts, ticket specs, graph, and handoff were
   separate artifacts with separate jobs.
4. Stable requirement/finding/ticket IDs made later work traceable even after
   GitHub issue numbers were assigned.
5. Tickets included enough scope, exclusions, evidence, acceptance, and tests
   for an agent that missed the research.
6. Dependencies and file/contract overlap were both considered when maximizing
   parallel work.
7. Research/audit gates preceded uncertain architectural changes.
8. Integration and feature-level acceptance eventually received an explicit
   owner.
9. Handoffs recorded durable policy and next queries so another model could
   recover after an interruption.

## What repeatedly failed

| Failure | Consequence | Rule for this work |
|---|---|---|
| Draft PR or handoff treated as live state | Counts, labels, PR status, and blockers drifted within hours | Docs preserve intent; query GitHub and Aiur for current facts. |
| Dependencies existed only in prose | Published issue graph diverged from the plan | Publish native relationships and requery them. |
| Phase used as a universal barrier | Safe parallelism was hidden and later waves serialized unnecessarily | Phase is a hint; readiness comes from typed dependencies/conflicts/state/capacity. |
| Complexity lacked a rubric | Oversized programs were called a single ticket and routing became arbitrary | Calibrate 1–5 for size/uncertainty; track risk/capability separately. |
| Ticket IDs were regex-fragile or collided with finding IDs | Counts and references silently omitted work | Use full stable IDs and validate exact tokens. |
| Ticket docs were thin export stubs | Research was deferred to lower-context worker agents | Finish the stable ticket contract before materialization. |
| Implementation notes were treated as permanent contracts | Paths and line numbers decayed as main moved | Separate stable behavior from refreshable notes tied to a SHA. |
| Integration/capstone was added late | Locally correct slices did not form a working feature | Add a merged-base acceptance capstone on day one. |
| All children closed meant “feature done” | Final Executor outcome lacked proof | Track root acceptance and capstone evidence independently. |
| Execution-discovered work rewrote the original plan | Intent and scope growth became impossible to audit | Version the graph and mark `planned` versus `discovered`. |
| Review and monitoring created work faster than agents completed it | A finite feature became an open-ended reliability program and its percentage/ETA lost meaning | Classify every finding; return contained work to rework, defer P2/P3/optimizations, and freeze promotion when creation exceeds completion. |

## Precedent-specific strengths

PR #513 contributes cumulative findings, explicit duplicate/refinement/demotion
dispositions, adversarial rechecks of load-bearing claims, and grouping hundreds
of observations by implementation locus rather than one issue per finding.

PR #732 contributes behavior inventories, characterization-test evidence,
agent-versus-at-merge verification, write/contract surface analysis, and the
need to validate the documents with code rather than trusting hand-maintained
indices.

PR #971 contributes an Executor-centered PRD, brownfield reuse audit, versioned
design delta, one-way foundation contracts, and a realistic warning: ten
parallel tickets still needed a later integration ticket because no one owned
the composed flow.

## Ticket pickability gate

An executable ticket must have:

- one owning agent and one coherent observable outcome;
- one review/acceptance boundary;
- explicit scope and sibling non-goals;
- a stable contract and existing owner/reuse target;
- agent-runnable and at-merge evidence;
- dependency and conflict surfaces precise enough to schedule;
- a PR that can leave the repository green.

Split when an item has multiple independently shippable outcomes, bounded
contexts, public contracts, owners, or an internal phase plan. Merge when work
shares one root cause, owner/write seam, and verification boundary and separate
PRs would be artificial. Umbrellas organize but are not dispatched.

## Complexity rubric

- **1:** localized known-pattern change, narrow tests, little uncertainty.
- **2:** one component/subsystem, modest multi-file change, standard tests.
- **3:** one bounded context with a new contract or meaningful integration.
- **4:** cross-context or high-uncertainty work; split unless indivisible.
- **5:** irreducible cross-system/high-risk or capstone work with explicit
  decomposition review.

Complexity is neither risk nor model routing. Record those independently.

## Execution convergence contract

The planning pack must make the later stop condition executable: acceptance,
critical path, required documentation/cleanup, real end-to-end proof and the
root-closing owner are recorded before dispatch. The Executor protects that
boundary. Maximum parallelism means maximum progress toward the bounded
outcome, not maximum active-ticket or discovery count.

During execution, classify a new finding before creating work: independent
P0/P1 blocker, contained rework, deferred P2/P3, or optimization. Keep deferred
evidence without activating it, report critical path separately from
reliability work, and apply a backlog-growth circuit breaker whenever promoted
work outpaces completion. A later bounded hardening run can promote selected
deferred findings after the original feature finishes.

## Planning stop criteria

Research is complete when:

1. objective, smallest useful slice, non-goals, precedence, and feature-level
   acceptance are explicit;
2. boundary-changing questions are answered or represented as owned gates;
3. load-bearing decisions cite current repository/design/tracker evidence;
4. adversarial review has dispositioned high-severity claims and dissent;
5. every requirement/finding has exactly one disposition;
6. every executable ticket passes the pickability gate;
7. integration and root acceptance have named owners and evidence;
8. graph/metadata/write-surface validation passes;
9. two successive relevant reviews add no high-severity or boundary-changing
   finding; and
10. the pack is committed, pushed, and restartable.

These are planning stop conditions. They do not authorize implementation or an
Aiur run.
