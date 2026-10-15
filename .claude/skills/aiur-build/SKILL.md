---
name: aiur-build
description: "Research and decompose a large feature into a durable, reviewable Aiur planning pack: requirements, versioned design evidence, technical decisions, worker-ready ticket contracts, typed dependency/conflict graph leveled into barrier-safe parallel phases within an agreed depth budget, validation report, and Executor handoff. Use when asked to break a feature into Aiur tickets, plan an epic/build order, reproduce a large-feature planning process, or prepare work for a later aiur-run. This skill is planning-only unless the user separately authorizes Executor-owned GitHub ticket promotion; it never implements the feature or runs Aiur."
---

# Build an Aiur Planning Pack

Act as the **Feature Planner**: build the system of understanding that a later
Executor can execute. Reserve “Executor” for the human or agent operating
`aiur-run`. Do not implement tickets, run Aiur, review live implementation PRs,
or merge product work under this skill. The Executor owns any promotion of
researched ticket drafts into tracker issues.

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
is recommended and walk them through `/ce-setup` in Claude or the corresponding
`$ce-setup`/installer flow in Codex. Continue with equivalent manual research
only if they decline or installation is unavailable. Read each selected skill's
complete instructions before using it.

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
5. Record commit/push permission, GitHub ticket-promotion permission, and
   the planning-only boundary. Never infer permission to create issues or merge.
6. Allocate a stable feature slug, logical ticket prefix, and `plan_version`
   before tickets receive GitHub numbers.
7. Pin the finite feature boundary: acceptance criteria, critical path,
   documentation/cleanup, end-to-end proof, and the condition that ends the
   later run. Create an empty deferred-findings ledger so discoveries can be
   preserved without expanding active scope.

Commit and push small coherent checkpoints when authorized. Planning branches
preserve intent and evidence; they are not live fleet databases.

## Source precedence

Declare precedence for the effort and record exceptions. The default is:

1. current explicit operator decisions;
2. captured/versioned design for intended UI behavior;
3. accepted requirements and ADR/contracts;
4. GitHub for promoted ticket facts, labels, relationships, and lifecycle;
5. Aiur for runtime agent state, progress, alerts, and events;
6. planning documents for approved intent, evidence, and the baseline graph.

Never copy GitHub/Aiur state into prose and continue presenting it as current.

## Execute the ten-stage workflow

Follow the detailed reference. At a glance:

1. intake, identity, scope, and questions;
2. current repository, design, tracker, and prior-art grounding;
3. requirements brainstorm and sizing calibration without premature ticketing;
4. cumulative evidence and explicit decisions;
5. adversarial verification of load-bearing claims;
6. `ce-plan` synthesis of implementation units and candidate boundaries;
7. worker-sized ticket contracts and typed scheduling graph;
8. mechanical validation plus adversarial document review;
9. optional Executor-owned GitHub promotion;
10. durable runtime Executor handoff and stop.

Use parallel researchers for independent evidence tracks, not for fragmented
writing of one authoritative document. Give each researcher a bounded question,
shared evidence format, current repository SHA, and instruction not to edit the
same files. The Feature Planner must reconcile contradictions.

## Ticket boundary rule

An executable ticket must have one owning agent, one coherent outcome, one
review/acceptance boundary, and a PR that can leave the repository green. Split
work with multiple independently shippable outcomes, bounded contexts, public
contracts, or internal phase programs. Merge observations that share one root
cause, owner/write seam, and verification boundary.

Every executable ticket carries concrete implementation pointers — exact
files, module and function names, patterns to copy, one worked data shape —
verified against the researched commit and marked refreshable. Abstract
constraint prose alone is not worker-ready for low-tier models, and a named
reuse target that does not exist at the researched commit is a
review-blocking defect.

Complexity points measure size and uncertainty only:

- `1`: localized known-pattern change;
- `2`: one component/subsystem, modest multi-file work;
- `3`: one bounded context with a new contract or meaningful integration;
- `4`: cross-context/high-uncertainty; split unless intrinsically indivisible;
- `5`: irreducible cross-system risk or capstone, with explicit rationale.

Track risk and capability needs separately. A ticket with its own multi-phase
plan is usually an umbrella, not an executable complexity-5 ticket.

Define discovery policy before handoff: P0/P1 acceptance blockers may be
promoted, contained review findings return to the owning ticket, and P2/P3 or
optimization findings stay in the deferred ledger. The later Executor must not
turn useful observations into an open-ended feature backlog.

## Model the graph correctly

Use hard `depends_on` only for semantic start/merge prerequisites. Represent
resource or merge conflicts as `serializes_with`, advisory order as
`suggested_after`, hierarchy as `contains`, and external constraints as gates.

Design the graph for parallel execution, not just correctness: compute the
wave profile and critical path before approval; dissolve same-wave
serialization cliques by re-partitioning write surfaces (one module per
page/section mounted by a shared shell beats many tickets composing one
file); prefer reviewed-contract dependencies over proven-implementation
dependencies where an explicitly temporary path is specified; and mark the
top fan-out spine for first-slot staffing in the Executor handoff.
Treat phase as a rollout/presentation hint, not a global barrier. Readiness is
derived from hard dependencies, conflicts, current state, and capacity.

Include an audit/ADR gate when ownership is uncertain and an explicit
integration/feature-acceptance capstone from day one. Preserve planned versus
discovered ticket provenance as `plan_version` evolves.

## Output a collection into the continuous build

A new feature produces a feature collection appended to the repository's single
continuous build, never a standalone Build Order root. Keep requirements,
versioned design captures, evidence, decisions, ticket drafts, typed graph,
wave/critical-path analysis, validation report, and approved planning SHA in the
reviewable planning pack. These remain durable intent, not live runtime state.

Record the feature slug, display label, member logical IDs, optional feature
epics, and links to existing build tickets. Keep real prerequisites separate
from scheduling preferences. On promotion, record tracker-number mappings,
`feature:<slug>` label verification, queue name and rank, and placement evidence.
A collection is not a separate run or a new acceptance boundary for the repository.

Existing `build-order.json` packs and state-node discovery mirrors remain
readable history. Do not publish a new legacy runtime pack or create a root to
make a new feature visible. Use `aiur feature create` and `aiur feature add` when
promotion is authorized, following the intake procedure below.

Before handoff, verify promoted members in the continuous Build view; until
that view ships, use `aiur feature show <slug> --json` and `aiur queue show --json`
(`aiur build-orders` remains useful for legacy roots). An unpromoted planning
pack instead records the proposed collection and queue placement for the Executor;
it must not claim live membership or completed placement verification.

## Approval freeze and re-approval

Approval pins the planning SHA used to render and publish the pack. Do not edit
planning documents and treat the old approval as covering the new content. In
the window before promotion, those documents are still the source of truth: if
they change, commit the edits and explicitly re-approve the new SHA before
publication.

Re-approval is a reconciliation, not a delete-and-recreate operation. Its
report identifies unchanged, changed, added, and removed logical members;
unchanged and changed members retain their existing GitHub issue identities,
changed content is updated in place, and new members are added. Removed members
are reported for operator follow-up and are never deleted or invalidated by the
re-approval. After promotion, the separate transfer-of-authority rule below
applies: make subsequent edits on the ticket, not in the planning document.

## Optional GitHub promotion

Only the Executor promotes researched drafts, and only when the user explicitly
asks to create tickets or has already granted that authority; encourage
creating every researched, ready-to-begin ticket together. Per-phase promotion
is optional user complexity, never a hardcoded Aiur workflow.

Use `agent:queued` in the same creation request for executable members; the queue
promotes ready members to `agent:todo`. Never create first and label later.

Promotion is deliberately not machinery: the Executor creates each issue with
the corresponding `tickets/<ID>.md` content verbatim, records the returned
issue number in the pack's logical-to-tracker mapping, and freezes the document. **After
promotion, edits go to the ticket, never the doc.** This transfer of authority
is the anti-duplication rule.

Complete [continuous-build intake](../aiur-run/references/continuous-build-intake.md)
as part of promotion: create the feature collection, file members with their
feature and disposition labels, write native prerequisites (including real links
to existing work), join the registry, and enqueue every executable member.
Feature ownership and queue membership are separate writes; read both back and
repair partial intake before declaring success. Never create a Build Order root.
If the operator says “prioritize”, place the collection before the prior next-up
using priority labels and queue ordering, and report the displaced work.

Do not assume issue-number adjacency. Keep prose dependency tables as generated
human views, not a second source of truth.

## Handoff and stop

The handoff identifies the feature slug/plan version, approved planning commit,
GitHub selector, source precedence, decisions/contracts, unresolved human
gates, integration/acceptance owner, finite feature boundary, deferred-findings
ledger, backlog-growth circuit breaker, runtime terminal condition, and queries
for fresh state. It tells the next agent to use `aiur-run` and to write a
three-to-five-sentence goal summarizing its Executor role and authority.

Stop after the reviewed pack and any separately user-authorized Executor
promotion.
Do not start Aiur or implement the first ticket as a convenience.
