# Production-Readiness Refactor — Overview

Aiur goes from vibe-coded sprawl to production-ready: **the same complete
feature set, in dramatically less code** — modular, DRY, extensible, with
zero feature loss. Aiur's own agents execute the refactor ticket-by-ticket
via the aiur-loop, orchestrated by an Opus agent, merging into a long-lived
`v2` integration branch. Authoritative brief:
`fable-planning-prompt.md`. Spike plan:
`docs/plans/2026-07-06-001-refactor-production-readiness-planning-spike-plan.md`.

---

## Success criteria

1. Every feature in `feature-inventory.md` (1,062 entries) survives —
   verified per-PR via `Inventory-IDs:` + characterization tests.
2. `v2` is green after every single ticket (full `make ci` gate).
3. The giants are decomposed per the name map (~190 focused modules); the
   coverage `ignore_modules` list only shrinks; duplication clusters
   consolidated to single homes.
4. Adding a coding-agent backend = one module + one registry entry.
5. Docs site live at `/docs` (VitePress) with quick-start, configuration,
   concept, and skills pages.
6. The human tests the finished `v2` once and merges to main.

## Document index

| Doc | Role |
|---|---|
| `feature-inventory.md` (+ `feature-inventory/`) | the anti-regression contract (FI IDs) |
| `current-architecture.md` | how it's built today + pain analysis |
| `target-architecture.md` | end state, seams, name-map contract |
| `regression-safety.md` | testing strategy, tripwire, flake rules, halt rules |
| `phasing-and-parallelization.md` | phase model, dependency rules, duty split |
| `research-history-hotspots.md`, `research-arch/`, `research-docs-framework.md`, `research-v2-mechanics.md` | evidence artifacts |
| `tickets/` | the backlog (generated after the checkpoint) |

## Deviations from the brief (evidence-driven, per the brief's own rule)

1. **Backend seam is half-built** — registry exists; the ticket formalizes a
   `@behaviour` + migrates residual `agent_runner.ex` branches (not
   greenfield).
2. **#609 is session resume**, not a generic persistence layer; the seam
   carries resume semantics.
3. **Verification gate corrected** — the brief's worked example under-scoped
   it; real gate = `make ci` / the five dev-loop commands, with manual
   verification split to at-merge checks (executors can't run `aiurdev
   --test*`).
4. **Feature inventory is split** into an index + 18 section files (~615 KB
   total would not render as one file).
5. **Issue conversion is done by the successor agent** (user decision), not
   the human: issues created in dependency order, `Depends-on` rewritten from
   the creation log, T-id→#N mapping verified before `agent:todo` labels go
   on. After conversion, the GitHub issue is the source of truth; ticket docs
   are frozen snapshots.
6. **`v2` integration branch** (user decision): all ticket PRs target `v2`;
   main untouched until final acceptance.
7. **Autonomous execution** (user decision): no human intervention between
   conversion and completion — see mandate below.
8. **Phase count is flexible** (the brief's wiggle-room clause governs);
   single-file chains run as serialized sub-waves under the delayed-open
   protocol.

## The Opus agent's mandate (autonomy model)

The agent running `/aiur-loop` for each phase:

- Uses each phase's aiur run itself as the integration test — a healthy
  fleet on `v2` validates prior merges.
- Owns PR readiness, green builds, merge conflicts, one-at-a-time merges,
  at-merge checks, and phase-exit.
- Opens new issues for unforeseen bugs/regressions and slots them into
  phases (same conventions, complexity 1–3 preferred).
- Is the backstop: if aiur becomes unusable, implement any fix necessary to
  restore the fleet, then record it (issue + PR into `v2`).
- Escalates to the human only at the two defined touchpoints (ticket-doc
  review; final `v2` acceptance) or when the change set itself is at risk.

## Conversion protocol (for the successor agent)

1. Human reviews `tickets/` and approves.
2. Operator setup: create `v2` from main; set `tracker.base_branch: "v2"` in
   the refactor run's `.aiur/config` (pre-ticket also updates `RepoBase` +
   CI; see `research-v2-mechanics.md`).
3. Create issues **in dependency order** (phase 1 first, sub-waves
   delayed-open — a dependent's issue is created only after its blocker
   merges). Rewrite `Depends-on: T-NNN` to real issue numbers from your own
   creation log as you go.
4. Before applying `agent:todo` to any issue, verify the full T-id→#N map
   lined up as expected (single actor, serial creation — numbering cannot
   drift; verify anyway).
5. Maintain the T-id→#N table in this file (pass 2).

## Checkpoint (R13) — what the human approves here

The six docs above, and specifically: the phase model + sub-wave rules, the
name-map contract, the tripwire mechanics + prerequisite tickets, the
VitePress decision, the v2 mechanics pre-ticket, and the doc-drift
restore-or-fix-docs decisions (FI-DOC entries: chat-pane ANSI recorder,
`--record` screen.ansi, stale `make -C elixir` reference, PR-template vs
dev-loop contradiction — default: fix the docs, don't resurrect unbuilt
features). **Approved-at SHA: _recorded here at approval_.** After approval,
ticket generation begins; the final PR is reviewed as: docs = delta since the
approval SHA; `tickets/` = new content, reviewed in full.

## Ticket index (pass 2 — filled during generation)

_Placeholder: T-id · title · phase/sub-wave · depends-on · files — generated
in dependency order, updated per committed batch so the index diff is the
resume marker._
