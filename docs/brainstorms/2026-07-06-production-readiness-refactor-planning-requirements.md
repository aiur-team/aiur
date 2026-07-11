---
date: 2026-07-06
topic: production-readiness-refactor-planning
---

# Production-Readiness Refactor — Planning Spike Requirements

## Problem Frame

Aiur accreted features from many agents with divergent context: heavy duplication,
oversized files (`src/lib/aiur/orchestrator.ex` alone is 7,617 lines), and redundant
code paths. The refactor goal: same complete feature set in dramatically less code —
modular, DRY, extensible. This spike is **planning only**: it produces the planning
docs and a backlog of 30–60 issue-ready tickets that lesser agents execute later via
the aiur-loop. The authoritative brief is `docs/refactor/fable-planning-prompt.md`;
this document records the decisions, verification results, and deltas from the
brainstorm — it does not restate the brief.

Brief verification (2026-07-06): all named feature-anchor paths exist; LOC claims
accurate (orchestrator 7,617; github/client 2,597; init 2,253; agent_runner 2,215;
renderer 2,139; codex/coding_agent 1,997; pane_manager 1,839). `src/lib` totals 162
files / ~58.7k lines; 177 test files. The brief is treated as the requirements
baseline; deviations get recorded in `docs/refactor/00-overview.md`.

---

## Actors

- A1. Planning agent (this session): runs research, writes planning docs and tickets.
- A2. Human operator: reviews planning docs at the checkpoint, reviews the final PR,
  converts ticket docs to `agent:todo` issues.
- A3. Executor agents: lesser aiur-loop agents that run tickets later; tickets must
  make their work mechanical.
- A4. aiur-loop pipeline: label lifecycle (`agent:todo → in-progress →
  human-review/rework → merging → done`) plus `complexity:N` routing.

---

## Key Flows

- F1. Spike delivery
  - **Trigger:** this brainstorm completes.
  - **Actors:** A1, A2
  - **Steps:** research (conventions → feature inventory → history mining → norms)
    → design architecture/phasing → write 6 planning docs → ce-doc-review + fixes →
    **human checkpoint (hard gate)** → generate tickets → consistency pass → PR.
  - **Outcome:** one PR on `refactor-planning-prompt` containing brief + planning
    docs + ticket backlog. No issues opened.
  - **Covered by:** R1–R3, R11–R13

- F2. Ticket execution (later, out of this spike's scope but shapes ticket design)
  - **Trigger:** A2 opens a ticket doc as an `agent:todo` issue.
  - **Actors:** A3, A4
  - **Steps:** executor claims issue → follows exact scope → runs verification
    commands → repo green → PR → human review.
  - **Outcome:** behavior-preserving change lands; no feature lost; suite green.
  - **Covered by:** R4–R10

---

## Requirements

**Deliverables**
- R1. All output lands on the `refactor-planning-prompt` branch as a single PR; no
  implementation code, no GitHub issues opened.
- R2. Six planning docs in `docs/refactor/`: `00-overview.md`,
  `feature-inventory.md`, `current-architecture.md`, `target-architecture.md`,
  `regression-safety.md`, `phasing-and-parallelization.md` — contents per the brief.
- R3. 30–60 standalone, issue-ready tickets in `docs/refactor/tickets/`, each
  matching the brief's worked-example shape (title, phase, depends-on, labels,
  problem/context, exact scope, out of scope, acceptance criteria, verification).

**Refactor contract (what the tickets must guarantee)**
- R4. Zero feature loss: `feature-inventory.md` exhaustively enumerates every
  feature, flag, config option, skill, event, alert, and CLI command; it is the
  anti-regression contract.
- R5. Repo green after every ticket (build + tests); all changes behavior-preserving.
- R6. Phase-1 characterization tests + CI tripwire land before any risky change;
  every risky ticket references them. Net test goal: less test code, higher-value
  coverage, never a red suite.
- R7. ≤3 phases of ~10 parallel agents; within a phase, concurrent tickets never
  touch the same file; all dependencies explicit and resolvable.
- R8. Tickets carry the intelligence: exact files, exact approach, low
  `complexity:N`; the executor makes no design decisions.
- R9. Mandated tickets exist: Phase-1 gate (inventory + characterization tests/CI);
  coding-agent backend seam (behaviour/adapter, Codex + Claude migrated, no new
  backend); decomposition of `orchestrator.ex` and the other giants; docs framework
  + pages (quick-start, configuration, what-aiur-is pages, skills page split into
  user/driver skills vs workspace-agent skills).
- R10. Target norms: ≤20-line functions and ≤200-line files as guiding targets
  (judgment, not lint); aggressive DRY with abstractions pulled upward; propose
  adopting ethereum-optimism/actions CONTRIBUTING.md norms for aiur.

**Process**
- R11. Research-first order: (1) aiur-loop/using-aiur ticket conventions, (2)
  feature inventory from code + tests, (3) issue/PR history mining for regression
  hotspots and recurring themes, (4) fetch ethereum-optimism/actions
  CONTRIBUTING.md, (5) only then architecture + phasing.
- R12. Planning docs are self-reviewed with ce-doc-review and fixed before the
  checkpoint; work is committed and pushed incrementally.
- R13. Hard gate: human reviews the planning docs before any tickets are generated.

---

## Success Criteria

- The human can approve the phase model, architecture, and inventory from the six
  docs alone, without re-deriving anything from code.
- A lesser agent can pick up any ticket cold and complete it with zero design
  decisions, leaving the repo green.
- `00-overview.md` index, ticket files, phases, and dependency graph are fully
  consistent: every dependency resolves; no two same-phase tickets share a file.
- Every inventory feature maps to characterization/regression coverage or an
  explicit rationale for why it needs none.

---

## Scope Boundaries

- No implementation of the refactor — planning artifacts only.
- No new coding-agent backend (gemini/local/OSS/openrouter are motivation only).
- No dependency bumps except installing the chosen docs framework.
- No changes to the `its-everdred/claude-app-server` repo; only aiur-side client
  code is in refactor scope.
- No agent runtime/model architecture changes unless a specific ticket scopes it.
- No GitHub issues opened by the agent; the human converts ticket docs.

---

## Key Decisions

- Deliver on `refactor-planning-prompt` (brief + outputs reviewed as one PR):
  user decision, supersedes the brief's "new branch e.g. refactor-plan".
- Pause for human review after planning docs, before ticket generation: user
  decision (adds R13 to the brief's process).
- Docs framework chosen by research during planning (evaluate agent-friendly
  options against the existing Vite/TS site): user decision.
- Brief treated as requirements baseline after repo verification; deviations
  recorded in `00-overview.md` per the brief's own instruction.

---

## Dependencies / Assumptions

- `claude-app-server` is out of scope except the aiur-side client code that talks
  to it (assumption stated during brainstorm, unchallenged).
- Ticket shape must match the real conventions in `.claude/skills/aiur-loop/` and
  `.claude/skills/using-aiur/` — confirming these is research step 1.
- `ethereum-optimism/actions` CONTRIBUTING.md is fetchable from GitHub.

---

## Outstanding Questions

### Deferred to Planning

- [Affects R9][Needs research] Which docs framework fits `website/` (custom Vite/TS
  marketing site with the terminal-sim demo): Starlight, VitePress, Fumadocs,
  Docusaurus, or other.
- [Affects R6][Needs research] Characterization-test strategy for the tmux/TUI/OTP
  surfaces — what can be pinned headlessly vs. where integration/system tests must
  stand in. This is the highest-risk design area of the spike.
- [Affects R3, R7][Technical] Final ticket count and per-phase allocation.
- [Affects R10][Technical] Where the ≤200-line file target yields to judgment
  (e.g., renderers, config schema).

---

## Next Steps

-> `/ce-plan` for structured planning: research phase, then the six planning docs,
then ce-doc-review, then the human checkpoint (R13).
