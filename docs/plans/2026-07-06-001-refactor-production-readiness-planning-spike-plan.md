---
title: "refactor: Production-readiness refactor planning spike"
type: refactor
status: active
date: 2026-07-06
origin: docs/brainstorms/2026-07-06-production-readiness-refactor-planning-requirements.md
---

# refactor: Production-Readiness Refactor Planning Spike

## Overview

Produce the complete planning package for aiur's production-readiness refactor:
six planning docs in `docs/refactor/` plus 30–60 issue-ready ticket docs in
`docs/refactor/tickets/`, delivered as one PR on `refactor-planning-prompt`.
The refactor itself (executed later by aiur-loop agents, orchestrated by an
Opus agent driving `/aiur-loop`, with all ticket PRs merging into a long-lived
`v2` integration branch) consolidates ~58.7k LOC / 162 files into modular,
DRY, behavior-preserving code with zero feature loss. This plan covers the
spike only — no refactor implementation.

A hard human gate sits between the planning docs and ticket generation
(origin R13). Everything before the gate optimizes for the human being able to
approve the phase model, architecture, and safety mechanics from the docs alone.

---

## Problem Frame

Aiur accreted features from many agents with divergent context: `orchestrator.ex`
is 7,617 lines, six more files exceed 1,800 lines, duplicate code paths abound,
and the riskiest modules are exempt from coverage. The refactor must preserve
every feature while aiur's own agents execute it ticket-by-ticket — so the
planning package carries all the intelligence: exact scopes, safety mechanics,
and a characterization-test tripwire that makes lesser-agent execution
mechanical and low-risk. (See origin: `docs/brainstorms/2026-07-06-production-readiness-refactor-planning-requirements.md`;
authoritative brief: `docs/refactor/fable-planning-prompt.md`.)

---

## Requirements Trace

**Deliverables**

- R1. Single PR on `refactor-planning-prompt`; no implementation; no GitHub
  issues opened during the spike.
- R2. Six planning docs in `docs/refactor/` (00-overview, feature-inventory,
  current-architecture, target-architecture, regression-safety,
  phasing-and-parallelization).
- R3. 30–60 standalone issue-ready tickets in `docs/refactor/tickets/` matching
  the brief's worked-example shape.

**Refactor contract**

- R4. Zero feature loss; `feature-inventory.md` is the anti-regression contract.
- R5. Repo green after every ticket (on the `v2` integration branch);
  behavior-preserving changes only.
- R6. Phase-1 characterization tests + CI tripwire land before any risky
  change; every risky ticket references them.
- R7. Phases of ~10 parallel agents — nominally 3, more acceptable per the
  brief's wiggle-room clause (see decision 3); same-phase concurrent tickets
  never share files; dependencies explicit and resolvable.
- R8. Tickets carry the intelligence; executors make no design decisions.
- R9. Mandated tickets: Phase-1 gate, backend seam, giant-file decomposition,
  docs framework + pages.
- R10. Size/DRY norms as guiding targets; propose adopting
  ethereum-optimism/actions CONTRIBUTING.md norms.

**Process**

- R11. Research-first order (conventions → inventory → history → norms → design).
- R12. ce-doc-review self-review before the checkpoint; incremental commits/pushes.
- R13. Hard gate: human reviews planning docs before ticket generation.

**Origin actors:** A1 (planning agent), A2 (human operator), A3 (executor
agents), A4 (aiur-loop pipeline)
**Origin flows:** F1 (spike delivery), F2 (ticket execution)

---

## Scope Boundaries

- No refactor implementation — planning artifacts only.
- No new coding-agent backend; no dependency bumps except the docs framework.
- No changes to `its-everdred/claude-app-server`; only aiur-side client code in
  refactor scope.
- No GitHub issues opened during this spike. After the human reviews the
  ticket docs, issue creation is delegated to the successor agent
  (decision 6) — not done here.
- No agent runtime/model architecture changes unless a specific ticket scopes it.

### Deferred to Follow-Up Work

- Ticket execution itself: runs later via aiur-loop against the `v2`
  integration branch, guided by the produced docs.
- Opening the `needs-triage` cleanup issues this spike identifies but does not
  scope (e.g., the PR-template contradiction below).

---

## Context & Research

### Ticket contract (from `.claude/skills/using-aiur/` + `.claude/skills/aiur-loop/`)

- Labels: `agent:todo` + `complexity:N` + optional `model:<backend>`. This
  repo's `.aiur/config` routes complexity 1–3 → codex, 4–5 → claude. Backends:
  `codex`, `claude` (headless, not resumable), `claude-repl` (resumable).
- Branch is pre-created `aiur/<N>`; issue body is the contract ("follow the
  issue instructions exactly"); no ISSUE_TEMPLATE exists.
- Pre-PR gate (dev-loop.md, from `src/`): `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix test`, `mix credo --strict`,
  `mix dialyzer`. CI runs the make-target equivalents (`.github/workflows/ci.yml`):
  build, fmt-check + lint (= `specs.check` + credo), coverage (85% threshold),
  regression (tmux shell test), dialyzer.
- Executor agents are guard-blocked from `aiurdev --test*`; manual TUI
  verification happens outside executor workspaces (see decision 2).
- Dependency mechanics at runtime: `aiur_declare_blocker(issue#)` + blockee
  merges the blocker's branch (`git merge origin/aiur/<blocker-id>`) — not
  wait-for-main. Decision 3's delayed-open protocol avoids relying on this.
- `.github/CODEOWNERS` is a single wildcard rule (`*` → both owners). It is
  the authority signal for whose issue/PR comments agents act on (that role is
  unchanged by this plan), but it cannot serve as an edit guard — CODEOWNERS
  only routes review requests; it never blocks edits (see decision 4).

### Corrections to the brief (record in `00-overview.md` deviations)

- **Backend seam is half-built.** `src/lib/aiur/coding_agent.ex` already has a
  single registry (`backends/0`) with per-backend `adapter`, `transcript`,
  `resumable`, etc.; `orchestrator.ex` has no backend-literal branching.
  Residual inline branching lives in `src/lib/aiur/agent_runner.ex` (~lines
  638–1052: claude vs claude-repl session reporting, remote-session promotion,
  spawn-failure fallback). The seam ticket = formalize a `@behaviour` +
  migrate those residual branches, not build a registry.
- **Issue #609 is not a generic persistence layer** — it is cross-restart
  session resume for claude backends, built on `Aiur.SessionHandle` +
  `resumable?/1` (#605). "Preps #609" concretely means the behaviour carries
  session-identity/resume semantics cleanly.
- **The brief's worked-example verification block is too small.** The real
  gate is the five-command dev-loop gate / `make ci`, and manual verification
  must be split out (executors cannot run it).
- **The brief's "human converts tickets to issues" is superseded** (user
  decision, 2026-07-06): the successor agent creates the issues after human
  review of the ticket docs (decision 6).

### Test landscape and the coverage ratchet

- 173 test files, ~2,315 tests. `src/test/aiur/regression/` holds 19
  characterization-style tests — the pattern home for Phase-1 tripwire tests.
  Snapshot support exists (`src/test/support/snapshot_support.exs`, ANSI golden
  files, `UPDATE_SNAPSHOTS=1`).
- `src/mix.exs` exempts the giants (Orchestrator, AgentRunner, coding agents,
  GitHub client, PaneManager, Tmux, AgentList, all Opencode, all AiurWeb…)
  from the 85% coverage threshold. **New modules extracted from giants are not
  exempt** — decomposition tickets must ship tests for extracted modules, and
  shrinking `ignore_modules` becomes a measurable success criterion.
- **CI does not cover `website/` at all** — every job in
  `.github/workflows/ci.yml` runs make targets from `src/`. Website guards
  (`npm run typecheck`, `npm run assert` golden snapshot, `npm run build`)
  are manual conventions today (see decision 14).

### Institutional learnings (docs/plans/, docs/measurements/, project memory)

- Known flake mechanics that must become characterization-test rules: no exact
  counts on shared singletons; `assert_receive` ≥ 2000ms under `--cover`;
  unique `AIUR_RELEASE_NODE` for engine-path tests (a test once SIGKILLed the
  operator's BEAM — PR #498); isolate `:log_file` for anything touching
  `src/lib/aiur/events/` (SubscriptionStore disk-leak flake, partially fixed
  in #687); `Process.sleep`-based sync is banned (SlotPolicyTest flake #506).
- Proven decomposition house style (prewarm/attach simplification,
  `docs/brainstorms/2026-05-23-opencode-prewarm-spaghetti-audit.md` →
  `docs/measurements/2026-06-23-emfile-structural-fix-census.md`): audit
  first, one source of truth per fact (ETS registry), pure policy functions
  instead of synchronous GenServer call chains, no M×N fan-out; pin
  resource-fan-out invariants with census-style assertions.
- Executor realities: lesser agents satisfy the letter of acceptance criteria
  (make them grep-able + named passing tests); codex quota exhaustion silently
  stalls tickets (remedy: `model:claude` reroute); post-#720 main pushes
  notify rather than kill running agents.
- Regression-pinning tests that pruning must whitelist:
  `src/test/aiur/test_reset_test.exs` (label race),
  `src/test/aiur/agent_runner_test.exs` marker fan-out, the
  subscription-store isolation pattern, and the curated `render_state`
  `Map.take` pipeline in `src/lib/aiur/agent_list/app.ex`.
- Regression-hotspot lead: `docs/plans/2026-06-24-*.md` (~20 fix plans from one
  48-hour dogfood run: drain races, stale tmux sessions, workspace git
  metadata, config instance keys, shutdown reap).

### External norms (fetched from ethereum-optimism/actions CONTRIBUTING.md)

≤20-line functions / ≤200-line files / max-2 nesting as targets; extraction
trigger = second concrete usage; shareable code never lives in a concrete
backend (behaviour/base owns cross-cutting work, concrete stays thin, one
dependency direction); mock at boundaries, never pure utilities; every bug fix
adds a regression test; flaky tests get fixed or deleted; zero-new-warnings
ratchet. The norms-adoption proposal ticket adapts these to Elixir + the
existing gate (`make ci`, `mix specs.check`).

---

## Key Technical Decisions

1. **Ticket verification = CI parity.** Every ticket's agent-runnable
   verification is `make ci` from `src/` (or the five dev-loop mix commands)
   plus named targeted tests; `make regression` SKIPs without tmux — noted per
   ticket. No smaller substitute. Tickets touching `website/` additionally run
   the website gate (decision 14).
2. **Verification splits into "Agent gate" and "At-merge checks".**
   Executors cannot run `aiurdev --test*`; each ticket lists exact headless
   commands for the executor, and concrete manual TUI checks to run at merge
   time — performed by the aiur-driving Opus agent (which runs outside
   executor workspaces and can drive the real TUI), with the human's deep
   validation reserved for the final `v2` acceptance (decision 16).
3. **Dependencies use the delayed-open protocol; serialized same-phase chains
   are allowed.** A dependent ticket's issue is not opened until its blocker
   is merged to `v2` — this neutralizes the branch-merge-chaining race in
   every case, so single-file decomposition chains (e.g., `orchestrator.ex`)
   may run as operator-sequenced sub-waves *within* a phase: open the next
   chain issue only after the previous merges. Phase count is nominally 3 and
   may exceed it (the brief's wiggle-room clause) — the binding constraint is
   that each phase is packaged so an Opus agent can run it end-to-end via
   `/aiur-loop` (open batch → monitor → merge → phase-exit). Re-gate rule: if
   U10's ticket generation cannot fit the checkpoint-approved phase model,
   return to the human checkpoint before generating further tickets.
4. **Characterization tests are read-only for executors — enforced by CI.**
   They live under a dedicated path in `src/test/aiur/regression/`; a CI check
   (scoped into the Phase-1 gate ticket) fails any PR whose diff touches that
   path unless the PR carries an operator-applied override label (e.g.
   `regression-suite-change`). CODEOWNERS is advisory only here — the repo's
   wildcard rule makes it a no-op as an edit guard (its separate role as the
   comment-authority signal is unchanged). Every risky ticket states: a
   failing characterization test means your change is wrong — stop and report
   a blocker, never edit the test.
5. **Phase-exit checklist gates each phase.** All phase tickets merged to
   `v2`, `v2` CI green, characterization suite green, at-merge TUI checks
   passed; no next-phase issues opened while any current-phase ticket is
   unresolved.
6. **Issue conversion is done by the successor agent, in order.** After the
   human reviews the final ticket docs, the next agent creates the GitHub
   issues in dependency order — issue numbers are sequential and known at
   creation, so it rewrites each `Depends-on: T-NNN` from its own creation
   log as it goes. Before applying `agent:todo` labels, it verifies
   post-creation that the T-id→issue-number mapping lined up as expected
   (issues are opened by one actor, serially, so numbering cannot drift).
   `00-overview.md` documents this protocol for the successor agent. After
   conversion the GitHub issue is the source of truth; ticket docs are frozen
   snapshots.
7. **Structured ticket fields for mechanical validation.** Every ticket
   carries `Files:` (exact paths), `Inventory-IDs:` (FI-### from
   feature-inventory.md), and — for risky tickets — `Characterization-tests:`
   (the named tripwire tests protecting its area, per R6); a check script
   validates per-phase file disjointness, dependency resolution, index↔files
   consistency, and that every risky ticket carries a resolvable
   characterization-test reference.
8. **Inventory entries get stable FI-### IDs** with per-entry coverage
   pointers (characterization test or a concrete manual-check recipe) — this
   is the per-PR "no feature removed" review mechanic.
9. **Backend seam ticket scope corrected** (see brief corrections): formalize
   an `Aiur.CodingAgent.Backend` behaviour over the existing registry and
   migrate the residual `agent_runner.ex` branches; carry `resumable?`/resume
   semantics for #609.
10. **Decomposition tickets must test what they extract** (coverage ratchet);
    each names the extracted modules exactly as pinned in
    `target-architecture.md`'s module/path name map — renames require the
    operator to amend downstream ticket docs before opening them.
11. **Complexity stays 1–3; concurrency-touching tickets pre-apply
    `model:claude`** (matches `complexity-routing.md` guidance and the codex
    quota-stall reality).
12. **Two-pass docs with an approval SHA.** `00-overview.md`,
    `phasing-and-parallelization.md` tables, and regression-safety's
    inventory→coverage mapping finalize after ticket generation; the human
    checkpoint approves the phase model, budgets, and rules; the approved
    commit SHA is recorded so the final PR review diffs only the delta.
13. **Self-review may change *how*, never *whether*.** ce-doc-review findings
    that contradict brief mandates are queued as explicit checkpoint
    questions, not silently applied.
14. **Website tickets ship via the PR flow with their own gate.** Any ticket
    touching `website/` runs `npm run typecheck && npm run build &&
    npm run assert` (the golden-snapshot guard) as its agent gate, since repo
    CI verifies nothing under `website/`. A small prerequisite ticket adds a
    website CI job so `v2` stays mechanically green for website changes too.
    The docs-framework choice is made by U3's evaluation, committed in the
    planning docs; the terminal-sim demo and its golden snapshot must survive.
15. **Halt-and-repair is owned by the Opus agent.** Red `v2` or a
    characterization failure: the Opus agent pauses the loop, stops
    opening/claiming issues, opens a top-priority fix issue referencing the
    offender, amends affected downstream ticket docs, then resumes. Dialyzer
    errors outside a ticket's scope: rebase `v2` and rerun; still failing →
    out-of-scope `needs-triage` finding, not scope creep.
16. **All refactor work merges into a long-lived `v2` integration branch,
    not main** (user decision, 2026-07-06). Executor branches (`aiur/<N>`)
    cut from and PR against `v2`; the aiur-driving Opus agent owns PR
    readiness, green builds on `v2`, merge-conflict handling, and merging
    into `v2` when ready. Exactly two human touchpoints exist after the
    planning-docs checkpoint: review of the final ticket docs before the
    successor agent converts them, and acceptance testing of the completed
    `v2` branch before it merges to main. Main stays untouched for the
    refactor's duration. Design-verification item for U5/U7: confirm aiur's
    base-branch mechanics against a non-default branch (workspace branch
    creation, `branch.push` blocker detection, post-#720 notify-on-push, and
    CI triggering on PRs targeting `v2`), and specify any config or small
    pre-ticket needed.
17. **Executors are told to stay inside their declared scope.** Ticket
    boilerplate instructs the executor to avoid editing files outside the
    ticket's `Files:` list; enforcement is not mechanical — the aiur-driving
    Opus agent, as owner of PR readiness and merges (decision 16), handles
    any drift, conflicts, and rework routing.
18. **Execution is fully autonomous; each phase's aiur run is the
    integration test** (user decision, 2026-07-06). No human intervention
    occurs between ticket conversion and full change-set completion. The
    Opus agent runs aiur built from `v2` (including all prior merged phases)
    to execute each phase — so a healthy fleet run doubles as live
    validation that previous PRs work as expected. When unforeseen bugs or
    regressions surface, the Opus agent opens new issues itself and slots
    them into phases (the backlog is extendable, following the same ticket
    conventions). Backstop: if aiur becomes unusable, the Opus agent
    implements any fix necessary directly — outside the ticket system if
    needed — to restore the fleet, then records what it did (issue + PR into
    `v2`) for the audit trail.

---

## Open Questions

### Resolved During Planning

- Where deliverables land: `refactor-planning-prompt` branch, one PR (user).
- Checkpoint placement: after planning docs, before tickets (user).
- Docs framework: chosen by U3 evaluation during execution (user delegated).
- Same-phase dependencies: allowed as serialized delayed-open chains; phase
  count flexible; phases packaged for `/aiur-loop` (user, doc-review
  walk-through 2026-07-06).
- Tripwire guard: CI override-label check, not CODEOWNERS (user, walk-through).
- Issue conversion: successor agent creates issues in dependency order and
  verifies the mapping; no helper script (user, walk-through).
- Integration branch: all refactor PRs merge into `v2`; human validates `v2`
  before main (user, walk-through).
- Autonomy model: no human intervention between ticket conversion and
  change-set completion; the Opus agent uses each phase's aiur run as the
  integration test, opens new issues for unforeseen bugs, and holds backstop
  direct-fix authority (user, 2026-07-06).
- Website verification: standard website gate + prerequisite website CI job
  ticket (user, walk-through).
- Seam ticket scope, verification gate, coverage ratchet — per Key Technical
  Decisions above.

### To Present at the Human Checkpoint

- The concrete phase allocation and ticket-count arithmetic from U7 (including
  the orchestrator sub-wave chain lengths and any budget tension between
  ticket size, count, and the norm targets).
- The docs-framework choice from U3, with runner-up and rationale.
- Characterization-coverage extent per subsystem from U6 — including which
  inventory entries land on manual-recipe-only coverage and whether that is
  acceptable for zero-feature-loss.
- The `v2` base-branch mechanics verification outcome (decision 16) and any
  pre-tickets it requires.

### Deferred to Implementation (spike execution)

- Final ticket count and per-phase allocation: falls out of U7 once
  decomposition waves are designed (re-gate rule applies if it breaks the
  approved model).
- Extent of characterization coverage per subsystem: designed in U6 against
  the flake rules; tmux/TUI surfaces may get at-merge recipe coverage instead
  of headless tests where pinning is infeasible.
- Docs framework choice: U3 evaluation (Starlight, VitePress, Fumadocs,
  Docusaurus) against the existing Vite/TS site + terminal-sim constraints.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for
> review, not implementation specification.*

```mermaid
flowchart LR
    subgraph A [Phase A - research fan-outs]
        U1[U1 feature-inventory.md]
        U2[U2 history hotspot map]
        U3[U3 docs-framework memo]
    end
    subgraph B [Phase B - design docs]
        U4[U4 current-architecture.md]
        U5[U5 target-architecture.md]
        U6[U6 regression-safety.md]
        U7[U7 phasing-and-parallelization.md]
        U8[U8 00-overview.md pass 1]
    end
    subgraph C [Phase C - gate]
        U9[U9 ce-doc-review + fixes]
        GATE{{HUMAN CHECKPOINT<br/>approval SHA}}
    end
    subgraph D [Phase D - post-gate]
        U10[U10 generate 30-60 tickets]
        U11[U11 consistency check + PR]
    end
    U1 --> U4 & U6
    U2 --> U4 & U6
    U3 --> U5
    U4 --> U5 --> U6 --> U7 --> U8 --> U9 --> GATE --> U10 --> U11
```

The refactor's phase model itself (designed in U7) is expected to shape as:
Phase 1 = safety net + independent low-risk consolidation; middle phases =
decomposition waves (giant-file chains as serialized sub-waves per decision
3); final phase = consolidation, norms adoption, docs framework + pages. Each
phase is one `/aiur-loop` run by the Opus agent, merging into `v2`; U7
decides the real allocation under the same-phase no-shared-file constraint
and may use more than 3 phases if the arithmetic demands it.

---

## Implementation Units

### Phase A — Research fan-outs (parallel)

- [ ] U1. **Build `feature-inventory.md` via multi-modal workflow sweep**

**Goal:** The exhaustive, ID'd feature/behavior map — the anti-regression
contract (R4).

**Requirements:** R4, R11; F2 (reviewer mechanic)

**Dependencies:** None

**Files:**
- Create: `docs/refactor/feature-inventory.md`

**Approach:**
- Workflow fan-out with agents sliced by subsystem (cli, config, events,
  github, prewarm, alerts, opencode, codex, claude, orchestrator+agent_runner,
  pane/tmux/agent_list, aiur_web, workspace/init, scripts+engine, `.aiur/`
  artifacts, both skill families, website) each extracting entries against a
  fixed schema: FI-### ID, name, behavior, entry points, config knobs,
  evidence paths, existing test coverage, risk class.
- Cross-cutting sweeps by artifact type (every CLI command/flag, every
  `config/schema.ex` option, every event/alert name, every skill) so features
  are found by two independent angles.
- Completeness critic pass + merge/dedup before writing the doc.
- Entries with no automated coverage get a concrete manual-check recipe
  (decision 8).

**Test scenarios:**
- Test expectation: none — documentation artifact; correctness enforced by the
  two-angle sweep + critic pass and by U9 review.

**Verification:**
- Every subsystem directory under `src/lib/aiur/` and both skill families
  appear; spot-check that known features (e.g., `emit_alert` lifecycle,
  `agent:*` labels, prewarm, `--record`, workspace skills install #722) have
  entries with evidence paths.

- [ ] U2. **Mine issue/PR history into a committed hotspot map**

**Goal:** Regression hotspots, recurring bug classes, and duplication signals
that target the refactor's care (R11 step 3), persisted as a repo artifact.

**Requirements:** R11; feeds R6 prioritization

**Dependencies:** None

**Files:**
- Create: `docs/refactor/research-history-hotspots.md` (committed and pushed
  when U2 completes, per R12 — it is load-bearing input to U4 and U6 and must
  survive session loss)

**Approach:**
- Workflow fan-out over all 248 merged PRs + all issues (~730 numbers) in
  batches, plus the `docs/plans/2026-06-24-*.md` fix-plan wave; classify by
  subsystem/path, extract regression recurrences and fix-of-a-fix chains.
- Output: ranked hotspot map (path → incident count → themes) and a
  recurring-theme summary.

**Test scenarios:**
- Test expectation: none — research artifact.

**Verification:**
- Hotspot map committed on the branch; covers the known hot areas (tmux/pane
  races, drain/shutdown, label races, subscription flakes) and ranks them
  with evidence links.

- [ ] U3. **Docs-framework evaluation memo**

**Goal:** Commit to one docs framework for `website/` (user delegated to
research).

**Requirements:** R9 (docs ticket); origin deferred question

**Dependencies:** None

**Files:**
- Create: none directly (decision + rationale land in
  `docs/refactor/target-architecture.md` and the docs tickets)

**Approach:**
- Evaluate Astro Starlight, VitePress, Fumadocs, Docusaurus against: coexists
  with the existing Vite 6 + TS marketing site and terminal-sim demo (golden
  snapshot `npm run assert` stays green), Netlify + bun build, agent-friendly
  authoring (plain markdown, low config), maintenance weight.
- Web research for current (2026) state of each; pick one, record runner-up.

**Test scenarios:**
- Test expectation: none — decision memo.

**Verification:**
- Decision names the framework, integration shape (subpath vs subdomain vs
  merged build), and why the golden-snapshot guard survives.

### Phase B — Design docs (after A)

- [ ] U4. **Write `current-architecture.md`**

**Goal:** How it's built today + pain/theme analysis (the "why" for every
later ticket).

**Requirements:** R2; R11

**Dependencies:** U1, U2

**Files:**
- Create: `docs/refactor/current-architecture.md`

**Approach:**
- Supervision tree (from `src/lib/aiur.ex`), subsystem map, backend dispatch
  reality (registry + residual `agent_runner.ex` branches), oversized-file
  list (re-measured), duplication map, U2's hotspot/theme analysis, coverage
  exemption reality from `src/mix.exs`.

**Test scenarios:**
- Test expectation: none — documentation artifact.

**Verification:**
- Every claim carries a repo path; brief corrections included; hotspots ranked.

- [ ] U5. **Write `target-architecture.md`**

**Goal:** The modular end state + the module/path name map that downstream
tickets treat as a contract (decision 10).

**Requirements:** R2, R9, R10

**Dependencies:** U4, U3

**Files:**
- Create: `docs/refactor/target-architecture.md`

**Approach:**
- Module boundaries per subsystem; the formal `Aiur.CodingAgent.Backend`
  behaviour design over the existing registry (callbacks confirmed against
  the residual branches; resume semantics for #609); decomposition shapes for
  each giant using the prewarm house style; size/DRY norms mapping
  (optimism-actions → Elixir); docs-framework integration shape (from U3);
  the full new-module name map (path-level, pinned).
- Verify and specify the `v2` base-branch mechanics (decision 16): workspace
  branch creation off `v2`, `branch.push` detection, CI triggers for PRs
  targeting `v2`; scope any config change or pre-ticket this requires.

**Test scenarios:**
- Test expectation: none — documentation artifact.

**Verification:**
- Name map covers every module later tickets create; behaviour callback set
  justified against `agent_runner.ex` lines 638–1052; no new backend designed;
  `v2` mechanics verified or explicitly ticketed.

- [ ] U6. **Write `regression-safety.md`**

**Goal:** The testing strategy that makes "green after every ticket"
trustworthy for lesser agents.

**Requirements:** R2, R5, R6

**Dependencies:** U1, U2, U5

**Files:**
- Create: `docs/refactor/regression-safety.md`

**Approach:**
- Phase-1 characterization tripwire: what gets pinned, in
  `src/test/aiur/regression/`, following existing patterns + snapshot support;
  hard flake rules (no exact singleton counts, `assert_receive` ≥ 2000ms,
  unique `AIUR_RELEASE_NODE`, `:log_file` isolation, no `Process.sleep` sync).
- Read-only tripwire mechanics: the CI override-label check (decision 4) +
  per-ticket language; halt rule (decision 15); merge protocol on `v2` —
  one merge at a time per phase, update-branch + fresh CI before each merge
  (prevents semantic races between file-disjoint green PRs).
- Pruning rules: prune only when pinned code is gone or replaced by
  higher-level coverage; whitelist the named regression-pinning tests.
- Coverage ratchet: extracted modules must be tested; `ignore_modules` only
  shrinks; net-negative test LOC with higher-value coverage as the goal.
- Phase-1 prerequisites from learnings: global `:log_file` isolation ticket,
  SlotPolicyTest #506 fix ticket; plus the website CI job pre-ticket
  (decision 14).
- Inventory→coverage mapping declared two-pass (skeleton now, per-ticket
  mapping after U10).

**Test scenarios:**
- Test expectation: none — documentation artifact (its rules become ticket
  acceptance criteria).

**Verification:**
- Every flake rule and safety mechanic from research appears; the
  learning-driven Phase-1 tickets are mandated; pruning whitelist present.

- [ ] U7. **Write `phasing-and-parallelization.md`**

**Goal:** The phase model with the dependency and disjointness rules that
make ~10-agent parallel execution safe, packaged for an Opus agent driving
`/aiur-loop`.

**Requirements:** R2, R7

**Dependencies:** U5, U6

**Files:**
- Create: `docs/refactor/phasing-and-parallelization.md`

**Approach:**
- Phase model + budgets; delayed-open dependency protocol with serialized
  same-phase sub-waves for single-file chains (decision 3); phase-exit
  checklist on `v2` (decision 5); present the decomposition arithmetic
  explicitly (chain lengths per giant file vs ticket size vs phase count) and
  use more than 3 phases if needed.
- Duty split: the aiur-driving Opus agent owns everything between conversion
  and completion — opens each phase's batch, monitors, ensures PRs are ready
  and `v2` builds green, handles merge conflicts, merges, runs phase-exit
  checks, uses each phase's aiur run as live validation of prior phases,
  opens new issues for unforeseen bugs and slots them into phases, and acts
  as the backstop with direct-fix authority if aiur becomes unusable
  (decision 18). The human appears exactly twice after the checkpoint:
  ticket-doc review before conversion, and final `v2` acceptance before main.
- Quota-stall watch signal and `model:claude` reroute; concrete per-ticket
  tables declared two-pass.

**Test scenarios:**
- Test expectation: none — documentation artifact.

**Verification:**
- Rules are stated as checklists the Opus agent can execute; the
  no-shared-file constraint has a mechanical check (U11 script) referenced;
  the arithmetic section exists and is consistent with the ticket backlog
  shape U10 will generate.

- [ ] U8. **Write `00-overview.md` (pass 1)**

**Goal:** Problem, goals, success criteria, phase model summary, deviations
from the brief, issue-conversion protocol, checkpoint questions — index
placeholder for pass 2.

**Requirements:** R2; decisions 6, 12, 13

**Dependencies:** U4–U7

**Files:**
- Create: `docs/refactor/00-overview.md`

**Approach:**
- Include: brief deviations (seam half-built, #609 nuance, verification-gate
  correction, successor-agent conversion, `v2` integration branch,
  learning-driven Phase-1 additions); the successor-agent conversion protocol
  (create issues in dependency order, rewrite Depends-on from the creation
  log, verify the T-id→issue mapping before applying `agent:todo`); the
  checkpoint questions listed in Open Questions above; two-pass declaration +
  where the approval SHA will be recorded; the Opus agent's mandate
  (autonomous phase execution, run-as-integration-test, new-issue authority,
  backstop direct-fix powers — decision 18), since `00-overview.md` is the
  document that agent executes from.

**Test scenarios:**
- Test expectation: none — documentation artifact.

**Verification:**
- A reader can run the checkpoint from this doc alone (questions, what to
  approve, what happens next); the successor agent can run the conversion
  from this doc alone.

### Phase C — Review and gate

- [ ] U9. **ce-doc-review sweep, fixes, and the human checkpoint**

**Goal:** Self-reviewed docs, pushed, and the hard gate presented (R12, R13).

**Requirements:** R12, R13; decision 13

**Dependencies:** U8

**Files:**
- Modify: the six docs per findings

**Approach:**
- ce-doc-review across the six docs; apply fixes that change *how*; queue any
  mandate-level conflicts as checkpoint questions; commit/push; present the
  checkpoint with the questions from Open Questions above; on change
  requests: apply → cross-doc consistency pass → targeted re-review of
  changed docs → re-confirm. Record the approved SHA in `00-overview.md`.

**Test scenarios:**
- Test expectation: none — review/process unit.

**Verification:**
- Docs pushed; checkpoint presented; approval SHA recorded before any ticket
  file exists.

### Phase D — Post-gate

- [ ] U10. **Generate the ticket backlog (30–60 tickets)**

**Goal:** Issue-ready ticket docs carrying all the intelligence (R3, R8, R9).

**Requirements:** R3, R8, R9; decisions 1, 2, 4, 7, 10, 11, 17

**Dependencies:** U9 (approved)

**Files:**
- Create: `docs/refactor/tickets/T-*.md` (30–60 files)
- Modify: `docs/refactor/00-overview.md` (index, per batch),
  `docs/refactor/phasing-and-parallelization.md` + `regression-safety.md`
  (pass-2 tables)

**Approach:**
- Ticket shape = brief's worked example + structured `Files:`,
  `Inventory-IDs:`, and (for risky tickets) `Characterization-tests:` fields
  + split Agent gate / At-merge verification + the stay-in-scope boilerplate
  (decision 17) + website gate on website tickets (decision 14). All PRs
  target `v2` (decision 16).
- Mandated tickets first (Phase-1 gate incl. the tripwire CI guard, the two
  learning-driven tickets, and the website CI job; backend behaviour; giant
  decompositions as sub-wave chains; docs framework + pages), then the
  consolidation backlog from U4's duplication map.
- Generate in dependency-graph order, commit+push per batch, update the index
  per batch (the index diff is the resume marker if generation is
  interrupted).
- Re-gate rule (decision 3): if the backlog cannot fit the approved phase
  model, stop and return to the checkpoint.

**Test scenarios:**
- Test expectation: none — documentation artifacts (each ticket embeds its own
  named test requirements for executors).

**Verification:**
- Every ticket passes the U11 script; mandated tickets present; complexity
  labels 1–3 with `model:claude` where decision 11 applies.

- [ ] U11. **Consistency validation + final PR**

**Goal:** Mechanically verified internal consistency; the single deliverable
PR (R1).

**Requirements:** R1, R7; decision 7

**Dependencies:** U10

**Files:**
- Create: `docs/refactor/tickets/check-consistency.sh` (or `.exs` — small,
  documented, reusable by the successor agent)
- Modify: `docs/refactor/00-overview.md` (final index + approval SHA note)

**Approach:**
- Script checks: every `Depends-on` resolves to an existing ticket; no two
  same-phase concurrent tickets share a `Files:` entry (sub-wave chains
  exempt — they serialize by construction); every risky ticket's
  `Characterization-tests:` references resolve to real test files; index↔files
  bijection; every ticket has required sections + labels.
- PR body: plan summary, phase model, ticket count; notes that the six docs
  were checkpoint-approved at the recorded SHA and the ticket backlog is the
  new content to review.

**Test scenarios:**
- Happy path: well-formed backlog → script exits 0 with a summary table.
- Error path: introduce a same-phase file collision → script exits non-zero
  naming both tickets. Duplicate/unknown `Depends-on` → non-zero with the
  offending T-id. Missing required section → non-zero naming ticket + section.
- Error path: risky ticket with a `Characterization-tests:` entry naming a
  nonexistent test file → non-zero naming the ticket and the dangling
  reference.

**Verification:**
- Script green on the final backlog; PR open with the described body; no
  GitHub issues created.

---

## System-Wide Impact

- **This spike adds only documentation** (plus one check script) — no runtime
  surface changes. The real blast radius is deferred to ticket execution and
  is governed by the safety mechanics the docs encode (halt rule, `v2` merge
  protocol, phase-exit checklist, CI-enforced read-only tripwire).
- **Unchanged invariants:** no source, config, CI, or website behavior changes
  in this PR; `docs/refactor/fable-planning-prompt.md` stays intact as the
  historical brief; main is untouched by the refactor until the human merges
  the validated `v2` branch.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Inventory misses a feature → silent loss later | Two-angle sweep (subsystem + artifact type) + completeness critic + FI-ID coverage mapping + manual-check recipes for untestable entries |
| Characterization infeasible on tmux/TUI surfaces | Existing `test/aiur/regression/` + snapshot patterns; where headless pinning fails, explicit at-merge manual-check recipes instead of fake coverage |
| History mining at 248 PRs / ~730 issues is noisy | Batched fan-out with fixed classification schema; the 2026-06-24 fix-plan wave as ground-truth calibration; output committed as a repo artifact |
| Checkpoint rework desyncs the six docs | Change-request loop: apply edits → cross-doc consistency pass → targeted re-review of changed docs → re-confirm |
| Ticket generation interrupted mid-stream | Dep-order batches, commit+push per batch, index-as-resume-marker |
| Executors game acceptance criteria or edit the tripwire | Grep-able criteria + named tests + CI override-label guard on the characterization path |
| Executor drifts outside declared `Files:` scope | Stay-in-scope ticket boilerplate; the aiur-driving Opus agent owns PR readiness, conflicts, and merges (decision 17) |
| aiur's loop mechanics assume the default branch | Decision 16 design-verification in U5: confirm workspace branching, push detection, and CI triggers against `v2`; pre-ticket any gap |
| Codex quota stalls mid-phase | Complexity 1–3 + pre-applied `model:claude` on concurrency tickets + stall watch signal in phasing doc |

---

## Sources & References

- **Origin document:** `docs/brainstorms/2026-07-06-production-readiness-refactor-planning-requirements.md`
- Authoritative brief: `docs/refactor/fable-planning-prompt.md`
- Ticket conventions: `.claude/skills/using-aiur/` (dev-loop, turn-workflow,
  complexity-routing, conventions), `.claude/skills/aiur-loop/SKILL.md`
- Backend registry: `src/lib/aiur/coding_agent.ex`; residual branches:
  `src/lib/aiur/agent_runner.ex`
- CI truth: `.github/workflows/ci.yml`, `src/Makefile`, `src/mix.exs`
  (coverage exemptions); `.github/CODEOWNERS` (wildcard rule)
- Decomposition precedent: `docs/brainstorms/2026-05-23-opencode-prewarm-spaghetti-audit.md`,
  `docs/measurements/2026-06-23-emfile-structural-fix-census.md`
- Related issues/PRs: #609 (resume), #605/#378 (SessionHandle), #506
  (SlotPolicy flake), #687 (subscription isolation), #498 (node-identity
  kill), #720 (main-push notify), #722 (workspace skills)
- External: ethereum-optimism/actions `CONTRIBUTING.md` (fetched 2026-07-06)
