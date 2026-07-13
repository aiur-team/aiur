---
name: aiur-build
description: "Research and decompose a large feature into a durable, reviewable Aiur planning pack: requirements, versioned design evidence, technical decisions, worker-ready ticket contracts, typed dependency/conflict graph, validation report, and Executor handoff. Use when asked to break a feature into Aiur tickets, plan an epic/build order, reproduce a large-feature planning process, or prepare work for a later aiur-run. This skill is planning-only unless the user separately authorizes GitHub issue materialization; it never implements the feature or runs Aiur."
---

# Build an Aiur Planning Pack

Act as the **Planning Executor**: build the system of understanding that a later
runtime Executor can execute. Do not implement tickets, run Aiur, review live
implementation PRs, or merge product work under this skill.

Read [the decomposition workflow](references/decomposition-workflow.md) before
starting. Read [the planning contract](references/planning-contract.md) before
choosing ticket boundaries or writing structured records.

## Recommended dependencies

Compound Engineering is strongly recommended:

- `ce-brainstorm` for requirements and decisions;
- `ce-plan` for the implementation plan;
- `ce-doc-review` for adversarial document review;
- browser/design, frontend, backend, security, or domain skills selected by
  evidence risk;
- `ce-code-review` belongs to the later runtime Executor, not this planning
  phase.

Check the available skills before beginning. If CE is absent, tell the user it
is recommended and walk them through `/ce-setup`. Continue with equivalent
manual research only if they decline or installation is unavailable. Read each
selected skill's complete instructions before using it.

## Start durably

1. Read repository instructions, contribution gates, current branch state, and
   relevant tracker conventions.
2. Preserve the original request and constraints. If the user requests a
   persistent run, create a three-to-five-sentence goal covering research,
   planning artifacts, ticket contracts, review, and the explicit stop before
   implementation.
3. Create a dedicated planning branch without disturbing unrelated work.
4. Create `questions-or-commands.md` immediately. Ask concise questions in chat
   and record every unanswered item there so asynchronous work can continue.
5. Record commit/push permission, GitHub issue-materialization permission, and
   the planning-only boundary. Never infer permission to create issues or merge.
6. Allocate a stable `build_order_id`, logical ticket prefix, and `plan_version`
   before tickets receive GitHub numbers.

Commit and push small coherent checkpoints when authorized. Planning branches
preserve intent and evidence; they are not live fleet databases.

## Source precedence

Declare precedence for the effort and record exceptions. The default is:

1. current explicit operator decisions;
2. captured/versioned design for intended UI behavior;
3. accepted requirements and ADR/contracts;
4. GitHub for materialized ticket facts, labels, relationships, and lifecycle;
5. Aiur for runtime agent state, progress, alerts, and events;
6. planning documents for approved intent, evidence, and the baseline graph.

Never copy GitHub/Aiur state into prose and continue presenting it as current.

## Execute the ten-stage workflow

Follow the detailed reference. At a glance:

1. intake, identity, scope, and questions;
2. requirements brainstorm without premature ticketing;
3. current repository, design, tracker, and prior-art grounding;
4. cumulative evidence and explicit decisions;
5. adversarial verification of load-bearing claims;
6. worker-sized ticket synthesis with full requirement disposition;
7. typed graph, phase hints, complexity, write/contract conflict analysis;
8. mechanical validation plus CE document review;
9. optional GitHub materialization and post-publish reconciliation;
10. durable runtime Executor handoff and stop.

Use parallel researchers for independent evidence tracks, not for fragmented
writing of one authoritative document. Give each researcher a bounded question,
shared evidence format, current repository SHA, and instruction not to edit the
same files. The Planning Executor must reconcile contradictions.

## Ticket boundary rule

An executable ticket must have one owning agent, one coherent outcome, one
review/acceptance boundary, and a PR that can leave the repository green. Split
work with multiple independently shippable outcomes, bounded contexts, public
contracts, or internal phase programs. Merge observations that share one root
cause, owner/write seam, and verification boundary.

Complexity points measure size and uncertainty only:

- `1`: localized known-pattern change;
- `2`: one component/subsystem, modest multi-file work;
- `3`: one bounded context with a new contract or meaningful integration;
- `4`: cross-context/high-uncertainty; split unless intrinsically indivisible;
- `5`: irreducible cross-system risk or capstone, with explicit rationale.

Track risk and capability needs separately. A ticket with its own multi-phase
plan is usually an umbrella, not an executable complexity-5 ticket.

## Model the graph correctly

Use hard `depends_on` only for semantic start/merge prerequisites. Represent
resource or merge conflicts as `serializes_with`, advisory order as
`suggested_after`, hierarchy as `contains`, and external constraints as gates.
Treat phase as a rollout/presentation hint, not a global barrier. Readiness is
derived from hard dependencies, conflicts, current state, and capacity.

Include an audit/ADR gate when ownership is uncertain and an explicit
integration/feature-acceptance capstone from day one. Preserve planned versus
discovered ticket provenance as `plan_version` evolves.

## Validate before approval

Write the canonical planning baseline as `build-order.json` using the planning
contract, then run:

```bash
python3 .claude/skills/aiur-build/scripts/validate_build_order.py \
  docs/build-orders/<slug>/build-order.json
```

Validation must cover unique IDs, resolved references, acyclic hard edges,
phase contradictions, requirement dispositions, pickability metadata,
parallel write/contract conflicts, and capstone ownership. Fix errors; explain
and disposition warnings. Generate human tables and diagrams from the same
records rather than maintaining competing counts by hand.

Run `ce-doc-review` on requirements, technical decisions, the plan, ticket
contracts, and handoff using relevant lenses. Planning is complete only after
two successive relevant review passes add no high-severity or boundary-changing
finding and all required quality gates pass.

## Optional GitHub materialization

Only when explicitly authorized:

1. requery GitHub and deduplicate existing work;
2. create/update the Build Order root and implementation issues;
3. map stable logical IDs to returned repo-qualified issue identities;
4. publish native membership and dependency relationships;
5. requery and validate the published graph rather than trusting mutation
   responses;
6. make GitHub canonical for the materialized ticket facts.

Do not assume issue-number adjacency. Keep prose dependency tables as generated
human views, not a second source of truth.

## Handoff and stop

The handoff identifies the Build Order/version, approved planning commit,
GitHub selector, source precedence, decisions/contracts, unresolved human
gates, integration/acceptance owner, runtime terminal condition, and queries
for fresh state. It tells the next agent to use `aiur-run` and to write a
three-to-five-sentence goal summarizing its Executor role and authority.

Stop after the reviewed pack and any separately authorized issue publication.
Do not start Aiur or implement the first ticket as a convenience.
