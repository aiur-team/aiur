---
name: aiur-build
description: "Plan an Aiur feature: the aiur-specific layer on the shared build-order decomposition skill — planning-pack formats, continuous-build collection, approval freeze, GitHub promotion, and Executor handoff. Use when asked to break a feature into Aiur tickets, plan an epic/build order, or prepare work for a later aiur-run. This skill is planning-only unless the user separately authorizes Executor-owned GitHub ticket promotion; it never implements the feature or runs Aiur."
---

# Build an Aiur Planning Pack

This skill is the Aiur layer of feature planning. The general, tool-agnostic
decomposition rules live in the shared `build-order` skill; this skill adds only
what Aiur needs on top of them. Do not restate a general rule here — a second
copy is exactly the drift this layering exists to stop.

Act as the **Feature Planner**: build the system of understanding that a later
Executor can execute. Reserve “Executor” for the human or agent operating
`aiur-run`. Do not implement tickets, run Aiur, review live implementation PRs,
or merge product work under this skill. The Executor owns any promotion of
researched ticket drafts into tracker issues.

Read [the workflow](references/decomposition-workflow.md) for where each stage's
Aiur records go. Read [the planning contract](references/planning-contract.md)
before writing structured records.

## Layer on the shared `build-order` skill

Run `build-order` first and follow it for the general method:

- ticket boundaries: when work is one executable ticket, an umbrella, or two;
- the complexity scale and what each point means;
- the typed ticket graph — `depends_on`, `serializes_with`, `suggested_after`,
  `contains` and gates — with its phase leveling, wave profile, critical path
  and phase-depth budget;
- mechanical and semantic validation plus the adversarial document review;
- discovery policy: what a plan may promote, return to rework, or defer.

This skill owns the Aiur side of the same pack: the `tickets/<ID>.md` contract
and its headings, `build-order.json` and `product_features`, the continuous
build, approval and re-approval, GitHub promotion, and the Executor handoff.

Check that `build-order` is available before starting. When it is absent, tell
the user it is a required dependency of this skill and point them at the shared
skills install; do not rebuild its general rules here. A run that proceeds
without it says so in the handoff.

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

## Aiur identity before research

`build-order` owns intake. Record these Aiur facts alongside it:

1. a stable feature slug, logical ticket prefix, and `plan_version` before any
   ticket receives a GitHub number;
2. commit/push permission, GitHub ticket-promotion permission, and the
   planning-only boundary — never infer permission to create issues or merge;
3. the planning branch and `questions-or-commands.md`, so an unanswered
   question never stalls asynchronous work;
4. the finite feature boundary — acceptance criteria, critical path,
   documentation/cleanup, end-to-end proof, and the condition that ends the
   later run — plus an empty deferred-findings ledger for discoveries.

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

## Stages

`build-order` runs the ten stages and sets their exit criteria. [The
workflow](references/decomposition-workflow.md) records only what the Aiur pack
adds at each one: its identity, its records, its validation, its promotion and
its handoff. In short: research and decide with `build-order` and CE, write the
pack, validate it, freeze an approval, then promote or hand off.

## Size the work in Aiur

The complexity scale is `build-order`'s; Aiur maps each point to a planned
estimate, and only the Executor may move that number.

**Leave the estimate alone unless you have a strong, specific reason for an estimate override.** Planned estimates come from complexity (1, 2, 4, 7, 11 hours for complexities 1–5). For bigger or more uncertain work, fix the complexity label or split the ticket. Override only duration complexity does not capture, such as human review rounds, outside waits, or a long migration: `aiur ticket estimate <id> <hours> --reason "<cause> — from <old>h to <new>h"`. The operator sees the reason word for word on the planned card and in the ticket modal: write one line, at most 500 characters, that they can check. Undo with `aiur ticket estimate <id> --clear --reason "<why>"`. Only the Executor changes estimates; issue workers have no estimate tool.

## Land the graph as Aiur records

`build-order` defines the edge types and computes the phases. This skill records
where a planned edge lands in Aiur: a real start/merge prerequisite becomes a
native `blocked_by` link on promotion, a write-surface conflict stays in the
pack as `serializes_with` (Aiur does not enforce it), and an advisory order
becomes queue position. Mark the top fan-out spine for first-slot staffing in
the handoff.

Include an audit/ADR gate when ownership is uncertain and an explicit
integration/feature-acceptance capstone from day one. Preserve planned versus
discovered ticket provenance as `plan_version` evolves.

## Output a collection into the continuous build

A new feature produces a feature collection appended to the repository's single
continuous build, never a standalone Build Order root. Keep requirements,
versioned design captures, evidence, decisions, ticket drafts, typed graph,
wave/critical-path analysis, validation report, and approved planning SHA in the
reviewable planning pack. These remain durable intent, not live runtime state.

Record each product feature group in `product_features` with a stable slug,
display label, and a complete, non-overlapping `ticket_ids` partition. An epic
holds the pack's features, a feature holds tickets, and a lane is the technical
column a ticket belongs to, so each product feature's lanes stay lanes on that
feature. Also record links to existing build tickets. Keep real prerequisites separate
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

**Give promoted members a home-page lane through their feature collection.** Follow continuous-build intake below, defining the collection's lanes and assigning members with `aiur feature add <slug> <ids…> --lane <lane>` when needed. Choose column names using the lane guidance in [decomposition workflow](references/decomposition-workflow.md); new collections need no Build Order root. New packs label tickets `lane:<lane>`; existing legacy roots keep their sub-issue and `build-lane:<lane>` mapping. Tickets filed outside the collection follow the [Executor home-page lane rule](../aiur-run/references/executor.md).

Publication creates plain GitHub issue titles from the plan title; logical IDs
remain in the ticket body and publication receipt. It registers one epic for the
planning pack (`bo-<root number>`, the epic a Build Order root imports as), one
feature per `product_features` group inside that epic, and each feature's lanes
with their workstream icons, then assigns every published issue to exactly one
collection and its planned lane. Re-running publication reconciles the same
epic, collections and membership, and writes nothing new when they already
match.
The publisher runs the product `aiur` command from `PATH`; set
`AIUR_FEATURE_CLI` to an executable `aiur` or `aiurdev` path when it is not on
`PATH` or the package's runtime instance must be selected explicitly.

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
using priority labels and queue ordering, and report the displaced work. If the
operator gave no position, ask before enqueueing. Show the current queue order
and offer "Before <set>" choices, as the intake reference describes in step 1.

Do not assume issue-number adjacency. Keep prose dependency tables as generated
human views, not a second source of truth.

`scripts/render_build_order_review.py` renders the graph review (waves, typed
edges, critical path, progress, epics, features, lanes) from one
`build-order.v1` document, using the daemon when one is running and the pack walk
when it is not. See [the planning
contract](references/planning-contract.md#the-review-reads-the-published-document).

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

Add `experiment:feature` to the promoted root to measure it automatically; see `website/docs-app/concepts/experiments.md` (Measuring a feature).

Workstream metadata: choose a unique Heroicons v2 outline icon, a one-line summary of at most 100 characters, and an optional wave in `build-order.json`. A feature's lane icons must differ from the icons of the configured lanes whose label matchers hit the same ticket. See `references/planning-contract.md`.
