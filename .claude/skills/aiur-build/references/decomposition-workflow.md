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
- Stage 8: Executor-owned GitHub promotion
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
issue node ID after promotion.

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
- a plan-context navigation block linking the pack index, the graph/wave
  analysis, the decisions registry, and the ticket's implementation-pointers
  section, pinned to the approved planning commit (published issue bodies
  carry the ticket document verbatim, so workers navigate from their issue
  back to the whole plan);
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

**Phases are computed, not chosen.** A phase is an antichain of the
hard-dependency graph: after the graph is final, level it (longest-path from
roots) and publish each level as one phase with **zero internal `depends_on`
edges** — every member must be dispatchable the moment the prior phase
completes. Any consumer of the pack (dashboard, executor, human) may treat a
phase as a barrier, so the pack must guarantee the barrier is free. Thematic
grouping (foundations / data / surfaces / billing) goes in **lanes and epics**,
never in phase membership: a milestone phase silently serializes every lane
behind its slowest chain — CropTracker's Stripe lane started at effective wave 7
of 21 under milestone phases; under computed phases it starts at phase 4 of 9.
Derive readiness from hard dependencies, conflicts, tracker state, and available
capacity — never from phase membership alone.

**Phase-depth budget:** agree a target with the user during Stage 2 (default
5–10 for 40–120 tickets). If leveling exceeds the budget, run the
depth-reduction pass (below) before accepting the graph. Ticket IDs must not
encode phase membership — IDs are stable opaque identity; phase truth lives only
in the graph and projected labels.

Epic/lane labels are the planner's choice, not a fixed vocabulary. The
prototype's docs/frontend/backend/infra set is an example — choose lanes that
partition THIS feature's work into legible ownership columns (for example
plan-graph / runtime / dashboard-ui / accounting / platform), keep the set
small (3–6), fold a one-ticket lane into its nearest neighbor, and record the
chosen labels in the pack's label projection. Assign each epic a Heroicon whose
meaning fits the lane you defined — the dashboard renders epic columns from the
Heroicons v2 outline set, and an icon name is simply the SVG filename (for
example `share`, `bolt`, `rectangle-group`, `banknotes`, `server-stack`,
`sparkles`, `cpu-chip`, `chart-bar`, `circle-stack`, `shield-check`,
`book-open`). Pick per epic from what those names mean, not from a fixed list,
and record the chosen icon name for each lane in the pack's lane metadata (the
README lane index and Executor handoff): the strict `build-order.json` schema
and the GitHub label projection carry no icon field, so the name lives in pack
prose only. An unknown or absent name falls back to a generic glyph, so
rendering never needs a model call. Prefer a single Build Order containing every
ticket in the program over sibling packs: one graph maximizes how many agents
can work at once, and separation belongs in lanes and phases, not in
membership — split membership only when a track genuinely must not gate or be
gated by the feature's completion.

Analyze write surfaces and public contracts, not just file paths. Two tickets
editing different modules may still conflict on a route, schema, event topic,
API, generated asset, or acceptance fixture.

Design for parallelism; do not merely document its absence:

- After drafting the graph, compute its wave profile (longest-path levels),
  critical path, and which `serializes_with` pairs land in the same wave.
  Publish the wave table in the pack; same-wave serializations are the real
  parallelism losses. For each lane, also report its **earliest-start phase**: a
  lane that cannot start until after ~phase 3 without a cited CI-green reason is
  a design smell — billing, premium, infra, and UI lanes can almost always begin
  against contracts and fixtures in the first third of the program.
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

**Edge acceptance test.** An edge must pass one of two tests, cited in the pack
when non-obvious:

1. **CI-green test:** the dependent's PR cannot typecheck/test/merge without the
   prerequisite's merged code — real imports, same-file extension, shared
   migration journal.
2. **Contract-authority test:** starting without the prerequisite would force
   the ticket to invent a second, incompatible version of a shape the
   prerequisite owns.

"A's runtime data flows through B" fails both tests and is **not an edge** — it
is integration, owned by exactly one named integration ticket. Keep a ledger:
every data-flow coupling dropped from the graph must map to the integration
ticket that reconnects it; an orphaned coupling is a validation error (Stage 7).
Watch for the tell that edges contradict the plans: if a ticket's own plan says
"pure library, no mocks, fixtures only" but the graph blocks it behind storage
or another subsystem, the edge is wrong, not the plan.

**Depth-reduction playbook.** When the wave profile exceeds the phase budget,
apply in order of leverage, re-leveling after each mechanism and stopping when
the budget is met (publish before/after wave tables in the pack):

1. **Contract layer first.** Pull every shape definition — domain types,
   wire/API contracts (including premium/billing/error unions), DB schema,
   fixture kits — into the earliest waves as cheap, declarative tickets. All
   implementations import only the contract layer and their own files, never
   sibling implementations. This is the single biggest flattener: it converts
   most implementation→implementation edges into implementation→contract edges
   that all point at wave 2–4.
2. **Pure-library engines.** Scope engine tickets (decoders, interpreters, math,
   attribution) as pure deterministic libraries tested on fixtures;
   storage/store wiring either lives in a thin unit gated only on the schema
   ticket, or moves to the integration capstone.
3. **Fixture-first UI.** One early ticket generates a fixture dataset from the
   contracts; every screen binds {typed client, app shell, fixtures}, never a
   live endpoint. One late ticket swaps fixtures for live APIs and runs the e2e
   smoke.
4. **Cross-cutting concerns: plugin early, audit late.** Never scope "apply X
   across all routes/screens" as a late sweep that edges every route — ship the
   middleware/plugin + a gating map early so each route composes it at creation,
   and keep only a late audit ticket. (Entitlements, auth context, logging
   redaction, i18n, telemetry all fit this shape.)
5. **Migration-journal ownership.** Shared migration journals serialize every
   schema ticket in a package. Consolidate a package's tables into one or two
   declarative schema tickets, and give independent packages (billing,
   entitlements) their own journals so their schema work leaves the core chain
   entirely.
6. **Name-pinning.** When plans are prescriptive enough to pin load-bearing
   export names, a consumer in another package may gate on the *schema/contract*
   wave instead of the producer's implementation; plan-vs-landed-name drift
   becomes a review-blocking defect instead of a scheduling edge. Same-package
   extension remains a real edge (CI-green test).
7. **Fatten the bootstrap.** Wave 1 is inevitably the scaffold; make it ship the
   workspace skeletons, placeholder packages, shared primitives, and CI script
   names so wave 2 fans out maximally wide.
8. **Fold trivial tails.** A 1–2 ticket final wave that exists only because of
   one chain (a verify-after-package ticket, an adjacent same-package query
   module) usually folds into its parent ticket as a verification/scope unit.

## Stage 7: Mechanical and semantic validation

Run the bundled validator, then check semantics it cannot prove:

1. each ticket is pickable by one agent and can land green;
2. the graph expresses real prerequisites rather than preferences;
3. every cross-ticket contract has a single defining owner;
4. integration and feature acceptance have explicit evidence and an owner;
5. error/freshness/partial failure behavior is specified at provider seams;
6. issue count is an outcome of boundaries, not a target;
7. the current GitHub/in-flight-work snapshot was refreshed before approval;
8. all generated counts, tables, and diagrams agree with canonical records;
9. every phase is an antichain (zero internal `depends_on` edges) and phase
   count is within the agreed budget, or the exception is recorded;
10. every data-flow coupling dropped under the edge acceptance test is owned by
    a named integration ticket (the reconnection ledger is complete);
11. a per-lane earliest-start report exists and late-starting lanes cite their
    blocking edge;
12. no ticket ID encodes phase membership as semantic truth.

Commit a validation report with errors, warnings, reviewed SHA, artifact hashes,
and any accepted exceptions.

## Stage 8: Executor-owned GitHub promotion

This stage requires explicit user permission and is not hardcoded machinery.
The Executor asks whenever the user wants tickets created and encourages
promotion of every researched, ready-to-begin ticket. For each selected member,
create the tracker issue from `tickets/<ID>.md` verbatim, record its number in
the pack's `ticket` field, and freeze the document. **After promotion, edits go
to the ticket, never the doc.** Per-phase promotion is optional user complexity,
not an Aiur-imposed workflow.

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
