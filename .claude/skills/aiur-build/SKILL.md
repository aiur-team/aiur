---
name: aiur-build
description: "Research and decompose a large feature into a durable, reviewable Aiur planning pack: requirements, versioned design evidence, technical decisions, worker-ready ticket contracts, typed dependency/conflict graph, validation report, and Executor handoff. Use when asked to break a feature into Aiur tickets, plan an epic/build order, reproduce a large-feature planning process, or prepare work for a later aiur-run. This skill is planning-only unless the user separately authorizes GitHub issue materialization; it never implements the feature or runs Aiur."
---

# Build an Aiur Planning Pack

Act as the **Feature Planner**: build the system of understanding that a later
Executor can execute. Reserve “Executor” for the human or agent operating
`aiur-run`. Do not implement tickets, run Aiur, review live implementation PRs,
or merge product work under this skill.

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
5. Record commit/push permission, GitHub issue-materialization permission, and
   the planning-only boundary. Never infer permission to create issues or merge.
6. Allocate a stable `build_order_id`, logical ticket prefix, and `plan_version`
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
4. GitHub for materialized ticket facts, labels, relationships, and lifecycle;
5. Aiur for runtime agent state, progress, alerts, and events;
6. planning documents for approved intent, evidence, and the baseline graph.

Never copy GitHub/Aiur state into prose and continue presenting it as current.

## Execute the ten-stage workflow

Follow the detailed reference. At a glance:

1. intake, identity, scope, and questions;
2. current repository, design, tracker, and prior-art grounding;
3. requirements brainstorm without premature ticketing;
4. cumulative evidence and explicit decisions;
5. adversarial verification of load-bearing claims;
6. `ce-plan` synthesis of implementation units and candidate boundaries;
7. worker-sized ticket contracts and typed scheduling graph;
8. mechanical validation plus adversarial document review;
9. optional GitHub materialization and post-publish reconciliation;
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
Treat phase as a rollout/presentation hint, not a global barrier. Readiness is
derived from hard dependencies, conflicts, current state, and capacity.

Include an audit/ADR gate when ownership is uncertain and an explicit
integration/feature-acceptance capstone from day one. Preserve planned versus
discovered ticket provenance as `plan_version` evolves.

## Validate before approval

Write the canonical planning baseline as `build-order.json` using the planning
contract and [validated example](references/build-order.example.json). Resolve
the loaded skill directory, then run its validator. Common repo-local paths are
`.claude/skills/aiur-build` and `.codex/skills/aiur-build`:

```bash
python3 <loaded-skill-directory>/scripts/validate_build_order.py \
  docs/build-orders/<slug>/build-order.json
```

After GitHub materialization, supply the repository and approved root-body
template so the validator can derive body expectations with `git show` rather
than trusting hashes copied into the receipt:

```bash
python3 <loaded-skill-directory>/scripts/validate_build_order.py \
  docs/build-orders/<slug>/build-order.json \
  --repository-root . \
  --root-document docs/build-orders/<slug>/root-issue.md
```

For a live start gate, also pass the exact receipt commit and the explicitly
trusted repository branch recorded by the publication manifest:

```bash
python3 <loaded-skill-directory>/scripts/validate_build_order.py \
  docs/build-orders/<slug>/build-order.json \
  --repository-root . \
  --root-document docs/build-orders/<slug>/root-issue.md \
  --receipt-commit <RECEIPT_SHA>
```

The validator loads `trusted_repository_ref` from `publication.json` at both
approval and receipt commits; it does not accept caller-supplied ref authority.
Receipt-commit mode also requires an authenticated `gh` CLI. It performs two
fresh read-only GitHub snapshots and requires exact agreement across every
mapped issue, all-state marker matches, root membership, and native blockers
before accepting the immutable v3 receipt.

Materialized validation also freezes the current planning documents: every
ticket document must remain byte-for-byte equal to its approved source, and the
current root document may differ from its approved full template only through
deterministic `<APPROVED_SHA>` substitution. Missing, unreadable, unsafe,
symlinked, or drifted current sources fail closed; remote body expectations
still come only from `git show` at the approved commit.

Graph validation covers unique IDs, design/decision references, worker-document
shape, resolved edges, phase contradictions, dispositions, pickability,
parallel-safety conflicts, capstone ownership, and any GitHub reconciliation
receipt. Fix errors; explain and disposition warnings. The separate review
report records whole-pack gates the command cannot prove. Generate human tables
and diagrams from the same records rather than maintaining competing counts.

Run `ce-doc-review`, or an equivalent adversarial review when CE is unavailable,
on requirements, decisions, the plan, ticket contracts, and handoff. Run at
least one pass; repeat after any high-severity or boundary-changing finding.
Planning is complete when a relevant pass adds neither and all gates pass.

## Optional GitHub materialization

Only when explicitly authorized:

1. requery GitHub, deduplicate existing work, and freeze every reference-only
   issue that the user did not authorize for mutation or reuse; treat a closed
   logical-marker match as a conflict and never reopen it without separate
   authority;
2. create/update the Build Order root and implementation issues;
3. map stable logical IDs to returned repo-qualified issue identities;
4. publish native membership and dependency relationships;
5. generate each ticket body as the exact authority preamble plus its approved
   ticket document verbatim, and generate the root from its approved full-body
   template by replacing `<APPROVED_SHA>`; disable Git replace/graft object
   substitution for every approval and receipt read;
6. preserve that same post-approval document freeze in the current pack;
7. requery and validate the published graph, full labels, OPEN issue states,
   and bodies rather than trusting mutation responses: every body has exactly
   one schema-2 logical-ID/version/approval marker, exactly one approved-commit
   link, and a SHA-256 equal to the independently rendered approved body;
   record the full marker-query result set and require exactly one returned
   issue mapping per logical ID;
8. record the bounded reconciliation receipt defined by the planning contract;
9. make GitHub canonical for the materialized ticket facts;
10. immediately before publishing a successful live start gate, run
    receipt-commit validation against the all-OPEN v3 publication snapshot.
    Derive repository, root, plan version, approval, and root URL from the exact
    receipt commit; require that commit to contain the complete materialized
    pack and pass the trusted reconciliation validator before accepting the
    same-repository commit URL.
    Anchor the repository outside both receipt and caller data to the configured
    GitHub origin. Query the exact target of the explicitly trusted
    `refs/heads/...` repository branch and prove receipt and approval commits
    are ancestors, with approval also preceding receipt; object/API visibility
    alone is insufficient. Requery the ref after proof and require the same tip.

The all-OPEN check is a publication-finalization snapshot, not a perpetual
invariant. After authorized execution begins, current GitHub lifecycle is live
truth; do not rerun publication validation to undo legitimate state changes.

Do not assume issue-number adjacency. Keep prose dependency tables as generated
human views, not a second source of truth.

## Handoff and stop

The handoff identifies the Build Order/version, approved planning commit,
GitHub selector, source precedence, decisions/contracts, unresolved human
gates, integration/acceptance owner, finite feature boundary, deferred-findings
ledger, backlog-growth circuit breaker, runtime terminal condition, and queries
for fresh state. It tells the next agent to use `aiur-run` and to write a
three-to-five-sentence goal summarizing its Executor role and authority.

Stop after the reviewed pack and any separately authorized issue publication.
Do not start Aiur or implement the first ticket as a convenience.
