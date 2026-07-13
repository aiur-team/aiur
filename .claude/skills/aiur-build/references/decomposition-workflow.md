# Decomposition Workflow

This workflow combines the strongest patterns from large feature, refactor, and
audit planning runs while avoiding their recurring failure: treating a draft PR
or hand-written handoff as a live ticket database.

## Contents

- Stage 0: Intake, identity, and boundary
- Stage 1: Research plan and grounding
- Stage 2: Requirements brainstorm
- Stage 3: Evidence and decisions
- Stage 4: Synthesis and adversarial review
- Stage 5: Plan and ticket synthesis
- Stage 6: Graph and scheduling
- Stage 7: Mechanical and semantic validation
- Stage 8: GitHub materialization
- Stage 9: Handoff and stop
- Scaling the workflow

## Stage 0: Intake, identity, and boundary

- Preserve the user's request verbatim or link to its durable source.
- Record objective, non-goals, constraints, terminal condition, repository,
  base branch, and explicit planning-only boundary.
- Allocate `build_order_id`, `plan_version`, and immutable logical ticket IDs.
- Create the planning branch and `questions-or-commands.md`.
- State source precedence and mutation authority.
- Record the researched repository SHA and relevant open PR/issue snapshot.
- Pin feature acceptance, critical path, required documentation/cleanup,
  required end-to-end proof, and the later run's terminal condition.
- Create a deferred-findings ledger before execution begins.

Good Build Order identity is stable before GitHub numbers exist. Prefer a
repository-scoped slug such as `owner/repo:feature-name`, plus an immutable root
issue node ID after materialization.

## Stage 1: Research plan and grounding

Choose evidence tracks by risk. Typical tracks are:

- current architecture and subsystem ownership/reuse;
- current-versus-target product and design delta;
- tracker, identity, dependency, and state contracts;
- history, prior planning runs, regressions, and failure modes;
- test, rollout, accessibility, security, and operations.

For UI work, capture external designs to the repository with original URL,
import timestamp, file hash, viewport/theme variants, and a delta/decision log.
A mutable design URL is not durable evidence. Inspect interactions as well as
screenshots and record prototype/spec drift explicitly.

Give parallel researchers the same SHA, scope, and evidence template:

```text
Claim / current behavior
Source and exact locus
Why it matters
Confidence and freshness
Contradiction or open question
Suggested requirement/decision impact
```

## Stage 2: Requirements brainstorm

Use `ce-brainstorm` when available after brownfield/design grounding. Capture:

- actors and operator workflows;
- requirement IDs and concrete acceptance examples;
- invariants, constraints, non-goals, and failure behavior;
- smallest useful end-to-end slice;
- resolved decisions and rejected alternatives;
- open questions whose answers change architecture or ticket boundaries.

Do not choose implementation tickets yet. An unanswered material question must
become an owned gate, not a silent assumption.

## Stage 3: Evidence and decisions

Maintain concise source-linked evidence packets. Use stable finding IDs only
when the breadth/risk justifies a ledger. For a compact product feature, stable
requirements, decisions, contracts, and tickets are usually enough.

Record:

- existing owner and reuse target for every proposed capability;
- current and target state/data flow;
- provider failure, freshness, and partial-degradation semantics;
- public contracts and which ticket may define or change them;
- agent-runnable, at-merge, and human/manual acceptance evidence;
- known conflicts with in-flight work.

Implementation paths and line numbers are refreshable notes tied to
`researched_at_commit`; they are not the durable contract.

## Stage 4: Synthesis and adversarial review

Start with coherence and feasibility, then select lenses appropriate to the
feature: product, design, accessibility, frontend, backend, data, security,
operations, scope, or adversarial verification.

Reviewers must relate findings to the shared requirements/decision set. Recheck
high-severity, high-complexity, and graph-defining claims independently. Record
duplicates, refinements, demotions, rejections, and unresolved dissent rather
than averaging them away.

Stop adding research tracks when two successive relevant passes produce no new
high-severity or boundary-changing fact. Do not use a fixed number of agents as
a proxy for confidence.

## Stage 5: Plan and ticket synthesis

Use `ce-plan` to synthesize implementation units, contracts, and verification
from the accepted requirements and evidence. Then group requirements/findings
by independently reviewable implementation outcome and change seam.

Every executable ticket needs:

- stable logical identity, kind, and provenance;
- problem/context and requirement/decision references;
- exact scope and explicit non-goals;
- existing owner/reuse target;
- stable contract/invariants and refreshable implementation notes;
- complexity rationale, separate risk, and capability needs;
- typed dependencies/conflicts and likely read/write/contract surfaces;
- error, security, migration, and accessibility concerns where relevant;
- agent gate, at-merge gate, and human/manual evidence owner where relevant;
- sibling boundaries and unresolved question gates.

Give every requirement/finding exactly one disposition: owned by one or more
tickets, deferred with reason, rejected with reason, or already satisfied with
evidence.

Classify execution discoveries in advance: promote only P0/P1 acceptance
blockers, return contained review findings to rework, and preserve P2/P3 plus
optimizations in the deferred ledger. The active feature graph is finite.

Add an audit/ADR gate when the owning architecture is uncertain. Add the
merged-base integration/feature-acceptance capstone before execution, not after
parallel slices expose the missing boundary.

## Stage 6: Graph and scheduling

Author only forward hard prerequisites. Derive reverse `blocks`, ready sets,
and parallel views.

Edge types:

- `depends_on`: semantic start/merge prerequisite;
- `serializes_with`: tickets are otherwise independent but cannot execute or
  merge concurrently because of resource/write/contract conflict;
- `suggested_after`: advisory ordering only;
- `contains`: umbrella/hierarchy relation;
- `external_gates`: non-ticket gates with owners;
- `discovered_from`: provenance for execution-discovered work.

Phase is a presentation/rollout hint. It may aid batching, but it does not make
every earlier phase ticket a blocker. Derive readiness from hard dependencies,
conflicts, tracker state, and available capacity.

Analyze write surfaces and public contracts, not just file paths. Two tickets
editing different modules may still conflict on a route, schema, event topic,
API, generated asset, or acceptance fixture.

## Stage 7: Mechanical and semantic validation

Run the bundled validator, then check semantics it cannot prove:

1. each ticket is pickable by one agent and can land green;
2. the graph expresses real prerequisites rather than preferences;
3. every cross-ticket contract has a single defining owner;
4. integration and feature acceptance have explicit evidence and an owner;
5. error/freshness/partial failure behavior is specified at provider seams;
6. issue count is an outcome of boundaries, not a target;
7. the current GitHub/in-flight-work snapshot was refreshed before approval;
8. all generated counts, tables, and diagrams agree with canonical records.

Commit a validation report with errors, warnings, reviewed SHA, artifact hashes,
and any accepted exceptions.

## Stage 8: GitHub materialization

This stage requires explicit permission.

- Requery and deduplicate against open/closed work.
- Create or identify the Build Order root issue.
- Create/update tickets from approved contracts.
- Map logical IDs to returned node IDs and repo-qualified numbers.
- Publish membership and native issue-dependency edges.
- Render every expected body from files loaded with
  `git show <approved-commit>:<path>`; fail closed if the approved pack, root
  template, or a ticket document is absent.
- Freeze the current sources after approval: ticket documents remain
  byte-for-byte equal to their approved versions, and the root document permits
  only deterministic `<APPROVED_SHA>` substitution. Reject missing, unreadable,
  out-of-repository, symlinked, or drifted sources.
- Requery every relationship and logical-marker search. Require exactly one
  issue match per logical ID and compare each parsed marker/link/hash record to
  the independently rendered expected body; fail on missing, wrong, duplicate,
  or truncated evidence.
- Reject any returned mapping that reuses an existing issue recorded as
  reference-only or otherwise outside the user's mutation authority.
- If publication exposes a live reconciliation/start-gate comment, require its
  receipt URL to be the exact repository commit URL and prove that commit
  resolves before treating the comment as authoritative.
- Apply projected and required routing labels, record full observed labels in
  the receipt, and prove every forbidden dispatch/active-state label and every
  unprojected `human:*` routing label is absent.

For GitHub, a root issue with native sub-issues is a practical v1 membership
model. GitHub supports up to 100 direct sub-issues per parent; larger programs
need nested workstream umbrellas or a different index. Preserve logical IDs so
hierarchy changes do not rewrite planning identity.

## Stage 9: Handoff and stop

Write a durable Executor handoff with:

- Build Order ID/version and approved planning commit;
- objective, non-goals, smallest slice, and terminal condition;
- requirement, decision, design, ticket, validation, and acceptance links;
- GitHub selector and logical-ID mapping for current ticket truth;
- Aiur commands/queries for current runtime truth;
- readiness, capacity, review, merge, verification, incident, privacy, and bug
  policies;
- unresolved human gates and capstone owner.
- finite feature boundary, deferred-findings ledger, and the rule that freezes
  new ticket creation when created/promoted work outpaces completions.

Do not freeze PR verdicts, live agents, CPU values, current blockers, or progress
percentages into the handoff as durable truth. The runtime Executor re-queries
them at startup.

Stop here. Execution requires a separate `aiur-run` authorization.

## Scaling the workflow

### 8–15 tickets

Use one requirements doc, one current-target delta, one technical decision doc,
one test/rollout plan, three-to-five research tracks, at least one adversarial
pass (repeat after a high-severity or boundary-changing finding), and one
integration capstone.

### 15–40 tickets

Add per-domain evidence, workstream umbrellas, cross-lane contract owners, hot
write-surface analysis, and lane integration checkpoints. Umbrellas organize;
their children remain executable.

### 40–100 tickets

Add a formal finding/behavior ledger, historical hotspot analysis, batch review,
generated indices, per-lane acceptance, and versioned planned-versus-discovered
graphs. Validate the complete graph after every batch. Never hand-maintain a
100-row live status table.
