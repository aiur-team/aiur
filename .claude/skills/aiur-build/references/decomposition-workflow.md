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
- open questions whose answers change architecture or ticket boundaries;
- the user's rough estimate of how many tickets/components the work should
  break into, plus any phasing or parallelism expectations.

Treat the user's estimate as calibration, not a cap. The planner usually ends
up knowing the scope best; growing or shrinking the decomposition is expected.
The final pack must surface the delta from that starting estimate with
per-boundary justification the user can skim.

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

Implementation paths, module and function names, and data shapes are
refreshable notes tied to `researched_at_commit`, distinct from the durable
contract — but they are required ticket content, not optional color. Low-tier
worker models fail on abstract constraint prose alone: every executable
ticket must name the exact files to read and extend, the existing patterns to
copy, and the data shapes it produces or consumes, verified against the
researched commit, so a worker can start within minutes instead of re-deriving
the research. Verify every named reuse target actually exists at the
researched commit; a phantom target (a module, pipeline, or helper the pack
assumed) is a review-blocking defect.

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
- stable contract/invariants and a required implementation-pointers section
  (exact files to create/modify with full paths, module and function names,
  one worked example fixture or data shape, verified reuse targets), marked
  refreshable against `researched_at_commit`;
- for each producer/consumer contract pair, one concrete interface sketch
  (message JSON or struct typespec) in the producer ticket, quoted verbatim by
  consumers — cheap models copy well and reconcile badly;
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

Design for parallelism; do not merely document its absence:

- After drafting the graph, compute its wave profile (longest-path levels),
  critical path, and which `serializes_with` pairs land in the same wave.
  Publish the wave table in the pack; same-wave serializations are the real
  parallelism losses.
- A serialization clique — three or more same-wave tickets pairwise
  serialized on one write surface — is a design smell, not a scheduling fact.
  Restructure ownership so write surfaces are disjoint: one module per
  page/section mounted by a shared shell beats many tickets composing one
  module. Modularity, reusability, and parallelism improve together.
- Prefer contract dependencies over implementation dependencies: a consumer
  may start against a reviewed interface seam while the provider's
  implementation lands, when an explicitly temporary path is specified.
  Reserve hard `depends_on` for cases where consuming the unproven contract
  would create a second incompatible implementation.
- Keep integration capstones off the enrichment critical path: ship the
  minimum end-to-end slice with named, stubbed seams and integrate
  enrichments as parallel follow-ups.
- Identify the top fan-out tickets (the spine) and mark them for first-slot
  staffing in the Executor handoff; a stall there starves more of the fleet
  than any other ticket.

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

- Requery and deduplicate against open/closed work. Stop on a closed canonical
  marker match; never auto-reopen it.
- Create or identify the Build Order root issue.
- Create/update tickets from approved contracts.
- Map logical IDs to returned node IDs and repo-qualified numbers.
- Publish membership and native issue-dependency edges.
- Render every expected body from files loaded with
  `git show <approved-commit>:<path>` with Git replace refs disabled and any
  legacy `info/grafts` entry rejected in both the worktree Git directory and
  shared common directory; fail closed if the approved pack, root template, or
  a ticket document is absent.
- Freeze the current sources after approval: ticket documents remain
  byte-for-byte equal to their approved versions, and the root document permits
  only deterministic `<APPROVED_SHA>` substitution. Reject missing, unreadable,
  out-of-repository, symlinked, or drifted sources.
- Requery every relationship and logical-marker search. Require exactly one
  issue match per logical ID and compare each parsed marker/link/hash record to
  the independently rendered expected body; fail on missing, wrong, duplicate,
  or truncated evidence.
- Record v3 observed state for the root and every member and require exact
  `OPEN` at publication.
- Reject any returned mapping that reuses an existing issue recorded as
  reference-only or otherwise outside the user's mutation authority.
- If publication exposes a live reconciliation/start-gate comment, derive its
  repository, root, plan version, approval, and root URL from the exact receipt
  commit. Require that commit to contain the complete materialized pack and
  pass the trusted reconciliation validator; resolving an arbitrary local
  commit or accepting caller-supplied authority is insufficient. Bind the
  repository to a trusted configured GitHub origin outside the receipt. Record
  one explicit `trusted_repository_ref` as a full `refs/heads/...` branch in the
  publication manifest, query its exact target from GitHub at gate time, and
  prove both receipt and approval commits are ancestors. Prove strict
  approval-to-receipt order separately in a fresh graft-free clone of that
  branch and through GitHub's compare API. A fork-only PR commit can be
  API-visible through the base repository without being authoritative. Requery
  the ref after proof and require the same target; movement or deletion fails
  closed. Any present, nonregular, or uninspectable graft entry fails closed.
- Immediately before the successful gate mutation, run receipt-commit mode
  with authenticated `gh`; require two identical bounded live snapshots of all
  mappings, titles, bodies, labels, states, markers, members, and blockers.
  Pin every API GET to `github.com`, API version `2026-03-10`, and a finite
  timeout; request no more than 100 explicit pages or 10,000 items per endpoint.
- Apply projected and required routing labels, record full observed labels in
  the receipt, and prove every forbidden dispatch/active-state label and every
  unprojected `human:*` routing label is absent. Keep the `build-order` label on
  the root only. Record expected and observed issue-title maps, and compare both
  with titles rendered from approved document H1s.

For GitHub, a root issue with native sub-issues is a practical v1 membership
model. GitHub supports up to 100 direct sub-issues per parent; larger programs
need nested workstream umbrellas or a different index. Preserve logical IDs so
hierarchy changes do not rewrite planning identity.

Treat the all-OPEN proof as publication finalization only. Once authorized
execution begins, use current GitHub lifecycle and explicit gate evidence; do
not treat the receipt snapshot as a reason to reverse legitimate state changes.

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
